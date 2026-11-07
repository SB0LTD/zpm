//! Bounded Microsoft CRT argument decoding from a UTF-8 command line. The OS
//! UTF-16 conversion stays with the application. Returned spans borrow output.
const std = @import("std");
pub const Span = struct { begin: usize, end: usize };
pub const Error = error{ InvalidUtf8, Capacity, EmbeddedNul };
pub fn parse(input: []const u8, output: []u8, spans: []Span) Error!usize {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, input, 0) != null) return error.EmbeddedNul;
    var at: usize = 0;
    var used: usize = 0;
    var count: usize = 0;
    while (at < input.len) {
        while (at < input.len and (input[at] == ' ' or input[at] == '\t')) at += 1;
        if (at == input.len) break;
        if (count == spans.len) return error.Capacity;
        const begin = used;
        var quoted = false;
        while (at < input.len and (quoted or (input[at] != ' ' and input[at] != '\t'))) {
            var slashes: usize = 0;
            while (at < input.len and input[at] == '\\') { slashes += 1; at += 1; }
            const before_quote = at < input.len and input[at] == '"';
            const literal_slashes = if (before_quote) slashes / 2 else slashes;
            if (literal_slashes > output.len - used) return error.Capacity;
            @memset(output[used..][0..literal_slashes], '\\'); used += literal_slashes;
            if (before_quote) {
                at += 1;
                if (slashes % 2 == 1) {
                    try put(output, &used, '"');
                } else if (quoted and at < input.len and input[at] == '"') {
                    try put(output, &used, '"'); at += 1;
                } else quoted = !quoted;
            } else if (at < input.len and (quoted or (input[at] != ' ' and input[at] != '\t'))) {
                try put(output, &used, input[at]); at += 1;
            }
        }
        spans[count] = .{ .begin = begin, .end = used };
        count += 1;
    }
    return count;
}
fn put(output: []u8, used: *usize, value: u8) Error!void {
    if (used.* == output.len) return error.Capacity;
    output[used.*] = value; used.* += 1;
}
test "Windows arguments preserve Hebrew empty strings quotes and trailing backslashes" {
    var output: [512]u8 = undefined;
    var spans: [16]Span = undefined;
    const count = try parse("\"C:\\my app\\run.exe\" transcribe-audio \"שיעור א.wav\" \"\" a\\\"b \"C:\\tail\\\\\"", &output, &spans);
    const expected = [_][]const u8{ "C:\\my app\\run.exe", "transcribe-audio", "שיעור א.wav", "", "a\"b", "C:\\tail\\" };
    try std.testing.expectEqual(expected.len, count);
    for (expected, spans[0..count]) |want, span| try std.testing.expectEqualStrings(want, output[span.begin..span.end]);
    try std.testing.expectError(error.Capacity, parse("a b", &output, spans[0..1]));
    try std.testing.expectError(error.Capacity, parse("abc", output[0..1], &spans));
}
