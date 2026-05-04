// JSONL (JSON Lines) parser — iterate lines, delegate per-line parsing to @zpm/json
// Layer 0: Core
//
// Operates on raw byte slices. Splits a buffer into lines, skips empty lines,
// handles \r\n and \n line endings. Each non-empty line is returned as a slice
// suitable for field extraction via @zpm/json helpers.

const std = @import("std");
const json = @import("json");

/// Iterator over non-empty lines in a JSONL buffer.
pub const JsonlIterator = struct {
    data: []const u8,
    pos: usize,
    line_num: usize,

    /// Create a new iterator over the given JSONL data.
    pub fn init(data: []const u8) JsonlIterator {
        return .{
            .data = data,
            .pos = 0,
            .line_num = 0,
        };
    }

    /// Returns the next non-empty line as a byte slice, or null at EOF.
    /// Skips empty lines and handles both \n and \r\n line endings.
    pub fn next(self: *JsonlIterator) ?[]const u8 {
        while (self.pos < self.data.len) {
            const start = self.pos;

            // Find end of line
            while (self.pos < self.data.len and self.data[self.pos] != '\n') {
                self.pos += 1;
            }

            var end = self.pos;

            // Strip trailing \r for \r\n endings
            if (end > start and self.data[end - 1] == '\r') {
                end -= 1;
            }

            // Skip past the \n
            if (self.pos < self.data.len) {
                self.pos += 1;
            }

            self.line_num += 1;

            // Skip empty lines (after stripping \r)
            const line = self.data[start..end];
            if (line.len == 0) continue;

            // Skip whitespace-only lines
            var all_ws = true;
            for (line) |c| {
                if (c != ' ' and c != '\t' and c != '\r') {
                    all_ws = false;
                    break;
                }
            }
            if (all_ws) continue;

            return line;
        }
        return null;
    }

    /// Returns the current line number (1-based).
    /// After calling next(), this is the line number of the line just returned.
    pub fn lineNumber(self: *const JsonlIterator) usize {
        return self.line_num;
    }
};

/// Count the number of non-empty lines in a JSONL buffer.
pub fn countLines(data: []const u8) usize {
    var iter = JsonlIterator.init(data);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    return count;
}

/// Parse a single JSONL line — validates it looks like a JSON object
/// (starts with '{') and returns the line for field extraction via
/// json.getString(), json.getInt(), etc.
/// Returns null if the line is not a valid JSON object start.
pub fn parseLine(line: []const u8) ?[]const u8 {
    // Skip leading whitespace
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        i += 1;
    }
    if (i >= line.len) return null;

    // JSONL lines should be JSON objects
    if (line[i] == '{') return line;

    return null;
}

// ── Tests ──

const testing = std.testing;

test "jsonl: empty input" {
    var iter = JsonlIterator.init("");
    try testing.expect(iter.next() == null);
    try testing.expectEqual(@as(usize, 0), countLines(""));
}

test "jsonl: single line" {
    const data =
        \\{"task_id": "HumanEval/0", "prompt": "def foo():"}
    ;
    var iter = JsonlIterator.init(data);
    const line = iter.next();
    try testing.expect(line != null);
    try testing.expect(iter.next() == null);
    try testing.expectEqual(@as(usize, 1), countLines(data));
}

test "jsonl: multiple lines" {
    const data = "{\"a\": 1}\n{\"b\": 2}\n{\"c\": 3}\n";
    var iter = JsonlIterator.init(data);

    const l1 = iter.next().?;
    try testing.expectEqualStrings("{\"a\": 1}", l1);
    try testing.expectEqual(@as(usize, 1), iter.lineNumber());

    const l2 = iter.next().?;
    try testing.expectEqualStrings("{\"b\": 2}", l2);
    try testing.expectEqual(@as(usize, 2), iter.lineNumber());

    const l3 = iter.next().?;
    try testing.expectEqualStrings("{\"c\": 3}", l3);
    try testing.expectEqual(@as(usize, 3), iter.lineNumber());

    try testing.expect(iter.next() == null);
    try testing.expectEqual(@as(usize, 3), countLines(data));
}

test "jsonl: skip empty lines" {
    const data = "{\"a\": 1}\n\n\n{\"b\": 2}\n";
    var iter = JsonlIterator.init(data);

    const l1 = iter.next().?;
    try testing.expectEqualStrings("{\"a\": 1}", l1);

    const l2 = iter.next().?;
    try testing.expectEqualStrings("{\"b\": 2}", l2);

    try testing.expect(iter.next() == null);
    try testing.expectEqual(@as(usize, 2), countLines(data));
}

test "jsonl: handle \\r\\n line endings" {
    const data = "{\"a\": 1}\r\n{\"b\": 2}\r\n";
    var iter = JsonlIterator.init(data);

    const l1 = iter.next().?;
    try testing.expectEqualStrings("{\"a\": 1}", l1);

    const l2 = iter.next().?;
    try testing.expectEqualStrings("{\"b\": 2}", l2);

    try testing.expect(iter.next() == null);
    try testing.expectEqual(@as(usize, 2), countLines(data));
}

test "jsonl: trailing newline does not produce extra line" {
    const data = "{\"x\": 1}\n";
    try testing.expectEqual(@as(usize, 1), countLines(data));
}

test "jsonl: no trailing newline" {
    const data = "{\"x\": 1}";
    var iter = JsonlIterator.init(data);
    const line = iter.next().?;
    try testing.expectEqualStrings("{\"x\": 1}", line);
    try testing.expect(iter.next() == null);
}

test "jsonl: whitespace-only lines skipped" {
    const data = "  \t \n{\"a\": 1}\n   \n";
    try testing.expectEqual(@as(usize, 1), countLines(data));
}

test "jsonl: parseLine validates JSON object" {
    try testing.expect(parseLine("{\"key\": \"val\"}") != null);
    try testing.expect(parseLine("  {\"key\": \"val\"}") != null);
    try testing.expect(parseLine("not json") == null);
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("[1, 2, 3]") == null);
}

test "jsonl: field extraction via json helpers" {
    const data = "{\"task_id\": \"HumanEval/0\", \"prompt\": \"def foo():\"}\n{\"task_id\": \"HumanEval/1\", \"prompt\": \"def bar():\"}\n";
    var iter = JsonlIterator.init(data);

    const l1 = iter.next().?;
    const tid1 = json.getString(l1, "\"task_id\"");
    try testing.expect(tid1 != null);
    try testing.expectEqualStrings("HumanEval/0", tid1.?);

    const l2 = iter.next().?;
    const tid2 = json.getString(l2, "\"task_id\"");
    try testing.expect(tid2 != null);
    try testing.expectEqualStrings("HumanEval/1", tid2.?);
}
