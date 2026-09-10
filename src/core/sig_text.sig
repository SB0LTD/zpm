//! Allocation-free ASCII and UTF-8 inspection over caller-owned slices.
const mem = @import("sig_mem");

pub fn toLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

pub fn isLetter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

pub fn isAlphanumeric(byte: u8) bool {
    return isLetter(byte) or (byte >= '0' and byte <= '9');
}

pub fn trim(source: []const u8, delimiters: []const u8) []const u8 {
    var start: usize = 0;
    var end = source.len;
    while (start < end and mem.indexOfScalar(u8, delimiters, source[start]) != null) start += 1;
    while (end > start and mem.indexOfScalar(u8, delimiters, source[end - 1]) != null) end -= 1;
    return source[start..end];
}

pub const Split = struct {
    source: []const u8,
    separator: u8,
    offset: usize = 0,
    done: bool = false,

    pub fn next(self: *Split) ?[]const u8 {
        if (self.done) return null;
        const start = self.offset;
        if (mem.indexOfScalar(u8, self.source[start..], self.separator)) |relative| {
            self.offset = start + relative + 1;
            return self.source[start .. start + relative];
        }
        self.done = true;
        return self.source[start..];
    }

    pub fn reset(self: *Split) void {
        self.offset = 0;
        self.done = false;
    }
};

pub fn splitScalar(source: []const u8, separator: u8) Split {
    return .{ .source = source, .separator = separator };
}

/// Reject overlong encodings, surrogates, incomplete sequences, and values
/// beyond U+10FFFF. Valid ASCII control bytes remain a caller policy decision.
pub fn utf8ValidateSlice(source: []const u8) bool {
    var index: usize = 0;
    while (index < source.len) {
        const first = source[index];
        if (first < 0x80) {
            index += 1;
            continue;
        }
        const length: usize = if (first >= 0xc2 and first <= 0xdf) 2 else if (first >= 0xe0 and first <= 0xef) 3 else if (first >= 0xf0 and first <= 0xf4) 4 else return false;
        if (length > source.len - index) return false;
        const second = source[index + 1];
        if ((first == 0xe0 and second < 0xa0) or
            (first == 0xed and second >= 0xa0) or
            (first == 0xf0 and second < 0x90) or
            (first == 0xf4 and second >= 0x90)) return false;
        var tail: usize = 1;
        while (tail < length) : (tail += 1) {
            if (source[index + tail] & 0xc0 != 0x80) return false;
        }
        index += length;
    }
    return true;
}
