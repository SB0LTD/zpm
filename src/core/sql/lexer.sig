//! Byte-level SQL lexer for the bounded grammar (Layer 0).
//! Whitespace and `--` comments separate tokens; words are ASCII letters,
//! digits and `_`; string literals use `''` escaping. Callers keep `source`
//! alive for the statement; spans index into it.
const types = @import("types.sig");
const Error = types.Error;

pub const Quoted = struct {
    /// First raw byte after the opening quote.
    start: usize,
    /// Raw byte index of the closing quote.
    end: usize,
    /// Decoded length after collapsing `''`.
    len: usize,
};

pub const Lexer = struct {
    source: []const u8,
    position: usize = 0,

    pub fn space(self: *Lexer) void {
        while (self.position < self.source.len) {
            const byte = self.source[self.position];
            if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
                self.position += 1;
            } else if (byte == '-' and self.position + 1 < self.source.len and self.source[self.position + 1] == '-') {
                self.position += 2;
                while (self.position < self.source.len and self.source[self.position] != '\n') self.position += 1;
            } else break;
        }
    }

    pub fn take(self: *Lexer, byte: u8) bool {
        self.space();
        if (self.position == self.source.len or self.source[self.position] != byte) return false;
        self.position += 1;
        return true;
    }

    pub fn expect(self: *Lexer, byte: u8) Error!void {
        if (!self.take(byte)) return error.Syntax;
    }

    /// Returns the next word (possibly empty) and advances past it.
    pub fn word(self: *Lexer) []const u8 {
        self.space();
        const start = self.position;
        if (start == self.source.len or !types.letter(self.source[start])) return self.source[start..start];
        self.position += 1;
        while (self.position < self.source.len and (types.letter(self.source[self.position]) or types.digit(self.source[self.position]))) self.position += 1;
        return self.source[start..self.position];
    }

    pub fn takeWord(self: *Lexer, expected: []const u8) bool {
        const saved = self.position;
        if (types.keyword(self.word(), expected)) return true;
        self.position = saved;
        return false;
    }

    pub fn expectWord(self: *Lexer, expected: []const u8) Error!void {
        if (!self.takeWord(expected)) return error.Syntax;
    }

    pub fn unsigned(self: *Lexer, maximum: u64) Error!u64 {
        self.space();
        const start = self.position;
        var value: u64 = 0;
        while (self.position < self.source.len and types.digit(self.source[self.position])) : (self.position += 1) {
            const next: u64 = self.source[self.position] - '0';
            if (value > (maximum - next) / 10) return error.IntegerOverflow;
            value = value * 10 + next;
        }
        if (start == self.position) return error.Syntax;
        if (self.position < self.source.len and types.letter(self.source[self.position])) return error.Syntax;
        return value;
    }

    /// Scans a string literal whose opening quote was already consumed.
    /// Decoded bytes beyond `limit` raise TextCapacity at the first excess byte.
    pub fn quoted(self: *Lexer, limit: usize) Error!Quoted {
        const start = self.position;
        var len: usize = 0;
        while (self.position < self.source.len) {
            const byte = self.source[self.position];
            self.position += 1;
            if (byte == '\'') {
                if (self.position == self.source.len or self.source[self.position] != '\'')
                    return .{ .start = start, .end = self.position - 1, .len = len };
                self.position += 1;
            }
            if (len == limit) return error.TextCapacity;
            len += 1;
        }
        return error.Syntax;
    }

    pub fn finish(self: *Lexer) Error!void {
        _ = self.take(';');
        self.space();
        if (self.position != self.source.len) return error.Syntax;
    }
};

/// Copies a quoted literal's decoded bytes into `out` (len bytes).
pub fn decodeQuoted(source: []const u8, quoted: Quoted, out: []u8) void {
    var index = quoted.start;
    var written: usize = 0;
    while (index < quoted.end) {
        out[written] = source[index];
        written += 1;
        index += if (source[index] == '\'') 2 else 1;
    }
}
