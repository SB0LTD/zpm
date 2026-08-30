//! LSP position/offset math — Layer 0 (pure, no allocator, no I/O).
//!
//! Converts between LSP zero-based (line, character) pairs (UTF-16 code-unit
//! semantics) and byte offsets into a document. Reusable by any Sig LSP server.

const std = @import("std");

pub const Position = struct {
    line: u32 = 0,
    character: u32 = 0,
};

pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

/// Byte length and UTF-16 code-unit width of the UTF-8 sequence at bytes[0].
fn utf8Step(bytes: []const u8) struct { bytes: usize, units: u32 } {
    const c = bytes[0];
    if (c < 0x80) return .{ .bytes = 1, .units = 1 };
    if (c >= 0xF0 and bytes.len >= 4) return .{ .bytes = 4, .units = 2 }; // astral → surrogate pair
    if (c >= 0xE0 and bytes.len >= 3) return .{ .bytes = 3, .units = 1 };
    if (c >= 0xC0 and bytes.len >= 2) return .{ .bytes = 2, .units = 1 };
    return .{ .bytes = 1, .units = 1 };
}

/// Convert an LSP (line, character) position into a byte offset in `text`.
pub fn offsetAt(text: []const u8, pos: Position) usize {
    var offset: usize = 0;
    var line: u32 = 0;
    while (line < pos.line and offset < text.len) {
        if (text[offset] == '\n') line += 1;
        offset += 1;
    }
    var units: u32 = 0;
    while (units < pos.character and offset < text.len and text[offset] != '\n') {
        const step = utf8Step(text[offset..]);
        offset += step.bytes;
        units += step.units;
    }
    return offset;
}

/// Convert a byte offset into an LSP (line, character) position.
pub fn positionAt(text: []const u8, offset: usize) Position {
    const clamped = @min(offset, text.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    var units: u32 = 0;
    var j = line_start;
    while (j < clamped) {
        const step = utf8Step(text[j..]);
        units += step.units;
        j += step.bytes;
    }
    return .{ .line = line, .character = units };
}

/// Total number of lines in `text` (1-based count of newline-separated lines).
pub fn lineCount(text: []const u8) u32 {
    var lines: u32 = 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    return lines;
}

test "offsetAt / positionAt roundtrip on ascii" {
    const text = "abc\ndef\nghi";
    try std.testing.expectEqual(@as(usize, 6), offsetAt(text, .{ .line = 1, .character = 2 }));
    const p = positionAt(text, 6);
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 2), p.character);
}

test "offsetAt clamps past line end and doc end" {
    const text = "ab\ncd";
    try std.testing.expectEqual(@as(usize, 2), offsetAt(text, .{ .line = 0, .character = 99 }));
    try std.testing.expectEqual(text.len, offsetAt(text, .{ .line = 99, .character = 0 }));
}

test "positionAt counts astral code points as two utf-16 units" {
    const text = "a\u{1F600}b";
    const p = positionAt(text, 5);
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 3), p.character);
}

test "lineCount" {
    try std.testing.expectEqual(@as(u32, 1), lineCount("abc"));
    try std.testing.expectEqual(@as(u32, 3), lineCount("a\nb\nc"));
}
