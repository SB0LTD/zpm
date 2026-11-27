//! Strict, bounded importer for gotliv.asr.v1 JSONL evidence. The artifact is
//! immutable; decoded strings live in a caller-owned arena. Claimed audio and
//! model identities are retained separately from the artifact's own identity.
const std = @import("std");
const t = @import("root.sig");
pub const Error = error{ InvalidJson, Capacity, InvalidSchema, InvalidProvenance,
    InvalidSequence, InvalidSegment, IncompleteArtifact, InvalidUtf8 };
pub const Timing = enum { timestamp_tokens, audio_window };
pub const Result = struct {
    segments: []const t.Segment,
    timing: []const Timing,
    audio: []const u8,
    model: []const u8,
    audio_sha256: [64]u8,
    model_sha256: [64]u8,
    pcm_samples: u64,
};

pub fn parse(bytes: []const u8, arena: []u8, segments: []t.Segment, timing: []Timing) Error!Result {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var strings: Arena = .{ .bytes = arena };
    var result: Result = undefined;
    var count: usize = 0;
    var windows: u64 = 0;
    var metadata = false;
    var complete = false;
    var expected_sample: u64 = 0;
    var source_samples: u64 = std.math.maxInt(u64);
    var committed_begin_ms: u64 = 0;
    var committed_end_ms: u64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (complete) return error.InvalidSequence;
        var fields: [32]Field = undefined;
        const object = try objectFields(line, &fields);
        const kind = try stringValue(try required(object, "type"), &strings);
        if (!metadata) {
            if (!std.mem.eql(u8, kind, "metadata")) return error.InvalidSequence;
            if (!std.mem.eql(u8, try stringValue(try required(object, "schema"), &strings), "gotliv.asr.v1")) return error.InvalidSchema;
            if (!std.mem.eql(u8, try stringValue(try required(object, "engine"), &strings), "native-sig-whisper")) return error.InvalidProvenance;
            if (try unsigned(try required(object, "pcm_rate")) != 16000) return error.InvalidSchema;
            result.audio = try stringValue(try required(object, "audio"), &strings);
            result.model = try stringValue(try required(object, "model"), &strings);
            result.audio_sha256 = try digest(try stringValue(try required(object, "audio_sha256"), &strings));
            result.model_sha256 = try digest(try stringValue(try required(object, "model_sha256"), &strings));
            if (optional(object, "offset_samples")) |offset| expected_sample = try unsigned(offset);
            const rate = try unsigned(try required(object, "source_rate"));
            const frames = try unsigned(try required(object, "source_frames"));
            if (rate < 8000 or rate > 384000 or frames == 0) return error.InvalidSchema;
            const total = (@as(u128, frames) * 16000 + rate - 1) / rate;
            if (total > std.math.maxInt(u64) or expected_sample >= total) return error.InvalidSequence;
            source_samples = @intCast(total);
            metadata = true;
        } else if (std.mem.eql(u8, kind, "window")) {
            if (try unsigned(try required(object, "id")) != windows) return error.InvalidSequence;
            if (try unsigned(try required(object, "start_ms")) != expected_sample / 16) return error.InvalidSequence;
            const samples = try unsigned(try required(object, "samples"));
            const advance = try unsigned(try required(object, "advance_samples"));
            if (samples == 0 or samples > 480000 or advance == 0 or advance > samples or
                expected_sample > source_samples or samples > source_samples - expected_sample) return error.InvalidSequence;
            const finish = try stringValue(try required(object, "finish"), &strings);
            if (!std.mem.eql(u8, finish, "end_of_text") and !std.mem.eql(u8, finish, "no_speech") and
                !std.mem.eql(u8, finish, "token_limit") and !std.mem.eql(u8, finish, "context_limit")) return error.InvalidSchema;
            committed_begin_ms = expected_sample / 16;
            expected_sample += advance;
            committed_end_ms = expected_sample / 16 + @intFromBool(expected_sample % 16 != 0);
            windows += 1;
        } else if (std.mem.eql(u8, kind, "segment")) {
            if (count == segments.len or count == timing.len) return error.Capacity;
            if (try unsigned(try required(object, "id")) != count or windows == 0 or
                try unsigned(try required(object, "window")) != windows - 1) return error.InvalidSequence;
            if (!std.mem.eql(u8, try required(object, "speaker"), "null")) return error.InvalidSegment;
            const begin = try unsigned(try required(object, "start_ms"));
            const end = try unsigned(try required(object, "end_ms"));
            if (end < begin or begin < committed_begin_ms or end > committed_end_ms or
                (count > 0 and begin < segments[count - 1].start_ms)) return error.InvalidSegment;
            const precision = try stringValue(try required(object, "timing"), &strings);
            timing[count] = if (std.mem.eql(u8, precision, "timestamp_tokens")) .timestamp_tokens
                else if (std.mem.eql(u8, precision, "audio_window")) .audio_window else return error.InvalidSegment;
            const text = try stringValue(try required(object, "text"), &strings);
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSegment;
            segments[count] = .{ .id = count, .start_ms = begin, .end_ms = end, .text = text };
            count += 1;
        } else if (std.mem.eql(u8, kind, "complete")) {
            if (try unsigned(try required(object, "segments")) != count or
                try unsigned(try required(object, "windows")) != windows or windows == 0) return error.InvalidSequence;
            result.pcm_samples = try unsigned(try required(object, "pcm_samples"));
            if (result.pcm_samples != expected_sample) return error.InvalidSequence;
            const duration = result.pcm_samples / 16 + @intFromBool(result.pcm_samples % 16 != 0);
            for (segments[0..count]) |segment| if (segment.end_ms > duration) return error.InvalidSegment;
            complete = true;
        } else return error.InvalidSequence;
    }
    if (!metadata or !complete) return error.IncompleteArtifact;
    result.segments = segments[0..count];
    result.timing = timing[0..count];
    return result;
}

const Arena = struct {
    bytes: []u8, used: usize = 0,
    fn append(self: *Arena, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.used) return error.Capacity;
        @memcpy(self.bytes[self.used..][0..value.len], value);
        self.used += value.len;
    }
};
const Field = struct { key: []const u8, value: []const u8 };
fn required(fields: []const Field, key: []const u8) Error![]const u8 {
    return optional(fields, key) orelse error.InvalidSchema;
}
fn optional(fields: []const Field, key: []const u8) ?[]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.key, key)) return field.value;
    return null;
}
fn unsigned(value: []const u8) Error!u64 {
    if (value.len == 0) return error.InvalidSchema;
    for (value) |c| if (c < '0' or c > '9') return error.InvalidSchema;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidSchema;
}
fn digest(value: []const u8) Error![64]u8 {
    if (value.len != 64) return error.InvalidProvenance;
    var out: [64]u8 = undefined;
    for (value, 0..) |c, i| {
        if (!std.ascii.isHex(c)) return error.InvalidProvenance;
        out[i] = std.ascii.toLower(c);
    }
    return out;
}
fn hex4(bytes: []const u8) Error!u16 {
    if (bytes.len < 4) return error.InvalidJson;
    return std.fmt.parseInt(u16, bytes[0..4], 16) catch return error.InvalidJson;
}
fn stringValue(raw: []const u8, arena: *Arena) Error![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidSchema;
    const start = arena.used;
    var i: usize = 1;
    while (i < raw.len - 1) {
        const c = raw[i]; i += 1;
        if (c != '\\') { try arena.append(&.{c}); continue; }
        if (i == raw.len - 1) return error.InvalidJson;
        const escaped = raw[i]; i += 1;
        switch (escaped) {
            '"', '\\', '/' => try arena.append(&.{escaped}),
            'b' => try arena.append("\x08"), 'f' => try arena.append("\x0c"),
            'n' => try arena.append("\n"), 'r' => try arena.append("\r"), 't' => try arena.append("\t"),
            'u' => {
                if (i + 4 > raw.len - 1) return error.InvalidJson;
                const first = try hex4(raw[i..]); i += 4;
                var cp: u21 = first;
                if (first >= 0xd800 and first <= 0xdbff) {
                    if (i + 6 > raw.len - 1 or raw[i] != '\\' or raw[i + 1] != 'u') return error.InvalidJson;
                    const second = try hex4(raw[i + 2..]); i += 6;
                    if (second < 0xdc00 or second > 0xdfff) return error.InvalidJson;
                    cp = 0x10000 + (@as(u21, first - 0xd800) << 10) + second - 0xdc00;
                } else if (first >= 0xdc00 and first <= 0xdfff) return error.InvalidJson;
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidJson;
                try arena.append(encoded[0..length]);
            },
            else => return error.InvalidJson,
        }
    }
    const result = arena.bytes[start..arena.used];
    if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidUtf8;
    return result;
}
const Cursor = struct {
    bytes: []const u8, at: usize = 0,
    fn whitespace(self: *Cursor) void {
        while (self.at < self.bytes.len and std.mem.indexOfScalar(u8, " \t\r\n", self.bytes[self.at]) != null) self.at += 1;
    }
    fn eat(self: *Cursor, byte: u8) Error!void {
        self.whitespace();
        if (self.at == self.bytes.len or self.bytes[self.at] != byte) return error.InvalidJson;
        self.at += 1;
    }
    fn string(self: *Cursor) Error![]const u8 {
        const start = self.at;
        try self.eat('"');
        while (self.at < self.bytes.len) {
            const c = self.bytes[self.at]; self.at += 1;
            if (c == '"') return self.bytes[start..self.at];
            if (c < 0x20) return error.InvalidJson;
            if (c == '\\') {
                if (self.at == self.bytes.len) return error.InvalidJson;
                const escaped = self.bytes[self.at]; self.at += 1;
                if (escaped == 'u') {
                    if (self.at + 4 > self.bytes.len) return error.InvalidJson;
                    const first = try hex4(self.bytes[self.at..]); self.at += 4;
                    if (first >= 0xd800 and first <= 0xdbff) {
                        if (self.at + 6 > self.bytes.len or self.bytes[self.at] != '\\' or self.bytes[self.at + 1] != 'u') return error.InvalidJson;
                        const second = try hex4(self.bytes[self.at + 2..]); self.at += 6;
                        if (second < 0xdc00 or second > 0xdfff) return error.InvalidJson;
                    } else if (first >= 0xdc00 and first <= 0xdfff) return error.InvalidJson;
                } else if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", escaped) == null) return error.InvalidJson;
            }
        }
        return error.InvalidJson;
    }
    fn value(self: *Cursor, depth: usize) Error![]const u8 {
        if (depth > 16) return error.Capacity;
        self.whitespace();
        const start = self.at;
        if (start == self.bytes.len) return error.InvalidJson;
        switch (self.bytes[self.at]) {
            '"' => _ = try self.string(),
            '{', '[' => |opening| {
                self.at += 1;
                const closing: u8 = if (opening == '{') '}' else ']';
                self.whitespace();
                if (self.at < self.bytes.len and self.bytes[self.at] == closing) { self.at += 1; return self.bytes[start..self.at]; }
                while (true) {
                    if (opening == '{') { self.whitespace(); _ = try self.string(); try self.eat(':'); }
                    _ = try self.value(depth + 1);
                    self.whitespace();
                    if (self.at == self.bytes.len) return error.InvalidJson;
                    if (self.bytes[self.at] == closing) { self.at += 1; break; }
                    try self.eat(',');
                }
            },
            't', 'f', 'n' => {
                const word: []const u8 = switch (self.bytes[self.at]) { 't' => "true", 'f' => "false", else => "null" };
                if (!std.mem.startsWith(u8, self.bytes[self.at..], word)) return error.InvalidJson;
                self.at += word.len;
            },
            else => {
                if (self.bytes[self.at] == '-') self.at += 1;
                if (self.at == self.bytes.len) return error.InvalidJson;
                if (self.bytes[self.at] == '0') self.at += 1 else {
                    if (self.bytes[self.at] < '1' or self.bytes[self.at] > '9') return error.InvalidJson;
                    while (self.at < self.bytes.len and std.ascii.isDigit(self.bytes[self.at])) self.at += 1;
                }
                if (self.at < self.bytes.len and self.bytes[self.at] == '.') {
                    self.at += 1;
                    const begin = self.at;
                    while (self.at < self.bytes.len and std.ascii.isDigit(self.bytes[self.at])) self.at += 1;
                    if (self.at == begin) return error.InvalidJson;
                }
                if (self.at < self.bytes.len and (self.bytes[self.at] == 'e' or self.bytes[self.at] == 'E')) {
                    self.at += 1;
                    if (self.at < self.bytes.len and (self.bytes[self.at] == '+' or self.bytes[self.at] == '-')) self.at += 1;
                    const begin = self.at;
                    while (self.at < self.bytes.len and std.ascii.isDigit(self.bytes[self.at])) self.at += 1;
                    if (self.at == begin) return error.InvalidJson;
                }
            },
        }
        return self.bytes[start..self.at];
    }
};
fn objectFields(line: []const u8, out: []Field) Error![]const Field {
    var cursor: Cursor = .{ .bytes = line };
    try cursor.eat('{');
    var count: usize = 0;
    while (true) {
        cursor.whitespace();
        if (cursor.at < line.len and line[cursor.at] == '}') { cursor.at += 1; break; }
        if (count == out.len) return error.Capacity;
        const quoted = try cursor.string();
        const key = quoted[1 .. quoted.len - 1];
        if (std.mem.indexOfScalar(u8, key, '\\') != null) return error.InvalidSchema;
        for (out[0..count]) |prior| if (std.mem.eql(u8, prior.key, key)) return error.InvalidSchema;
        try cursor.eat(':');
        out[count] = .{ .key = key, .value = try cursor.value(0) };
        count += 1;
        cursor.whitespace();
        if (cursor.at < line.len and line[cursor.at] == '}') { cursor.at += 1; break; }
        try cursor.eat(',');
        cursor.whitespace();
        if (cursor.at < line.len and line[cursor.at] == '}') return error.InvalidJson;
    }
    cursor.whitespace();
    if (cursor.at != line.len) return error.InvalidJson;
    return out[0..count];
}

test "ASR importer decodes escaped evidence and preserves distinct identities" {
    const input = "{\"schema\":\"gotliv.asr.v1\",\"type\":\"metadata\",\"engine\":\"native-sig-whisper\",\"pcm_rate\":16000,\"source_rate\":16000,\"source_frames\":320,\"audio\":\"a.wav\",\"model\":\"m.bin\",\"audio_sha256\":\"" ++ "a" ** 64 ++ "\",\"model_sha256\":\"" ++ "b" ** 64 ++ "\"}\n" ++
        "{\"type\":\"window\",\"id\":0,\"start_ms\":0,\"samples\":320,\"advance_samples\":320,\"finish\":\"end_of_text\",\"tokens\":[50365,1,50366],\"scores\":[-1.2e-3,0]}\n" ++
        "{\"type\":\"segment\",\"id\":0,\"window\":0,\"start_ms\":0,\"end_ms\":20,\"timing\":\"timestamp_tokens\",\"speaker\":null,\"text\":\"a\\\"b\\u05e9\\ud83d\\ude00\"}\n" ++
        "{\"type\":\"complete\",\"windows\":1,\"segments\":1,\"pcm_samples\":320}\n";
    var arena: [1024]u8 = undefined;
    var segments: [4]t.Segment = undefined;
    var timing: [4]Timing = undefined;
    const parsed = try parse(input, &arena, &segments, &timing);
    try std.testing.expectEqualStrings("a\"bש😀", parsed.segments[0].text);
    try std.testing.expectEqualStrings("a" ** 64, &parsed.audio_sha256);
    try std.testing.expectEqualStrings("b" ** 64, &parsed.model_sha256);
    const footer = std.mem.lastIndexOf(u8, input, "{\"type\":\"complete\"").?;
    try std.testing.expectError(error.IncompleteArtifact, parse(input[0..footer], &arena, &segments, &timing));
    try std.testing.expectError(error.Capacity, parse(input, arena[0..4], &segments, &timing));
    var fields: [8]Field = undefined;
    try std.testing.expectError(error.InvalidSchema, objectFields("{\"type\":1,\"type\":2}", &fields));
    try std.testing.expectError(error.InvalidJson, objectFields("{\"x\":01}", &fields));
    try std.testing.expectError(error.InvalidJson, objectFields("{\"x\":\"\\ud800\"}", &fields));
}
