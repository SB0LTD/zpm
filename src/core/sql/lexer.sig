//! SQL lexers (Layer 0). Callers keep `source` alive for the statement; spans
//! index into it.
//!
//! `Tokenizer` is the statement-pipeline lexer (design §4.1): words (ASCII
//! case-folded on comparison), double-quoted identifiers that keep their case
//! (`""` escapes), string literals with `''` escaping, integer, decimal and
//! exponent literals, `$n` placeholders, the operators
//! `= <> != < <= > >= + - * / % || :: -> ->> #> #>> @> <@ ?` and punctuation,
//! with whitespace, `--` and (nested) `/* */` comments between tokens.
//!
//! `Lexer` is the frozen byte-level lexer of the alpha grammar. Only the
//! `legacy_alpha` recognizer (alpha.sig) uses it; it must never grow.
const types = @import("types.sig");
const Error = types.Error;

pub const Quoted = struct {
    /// First raw byte after the opening quote.
    start: usize,
    /// Raw byte index of the closing quote.
    end: usize,
    /// Decoded length after collapsing the doubled quote.
    len: usize,
};

pub const Kind = enum { end, word, quoted_word, string, integer, decimal, parameter, symbol };

/// Words the parser recognizes, classified once per token (quoted words are
/// never keywords).
pub const Keyword = enum {
    none,
    over, partition, current, preceding, following, unbounded, range, groups,
    abort,
    all,
    @"and",
    as,
    asc,
    at,
    begin,
    between,
    bigint,
    @"bool",
    boolean,
    by,
    case,
    cast,
    coalesce,
    commit,
    committed,
    create,
    date,
    decimal,
    default,
    delete,
    desc,
    double,
    drop,
    @"else",
    end,
    @"false",
    first,
    float,
    float4,
    float8,
    @"for",
    from,
    ilike,
    in,
    insert,
    int,
    int2,
    int4,
    int8,
    integer,
    interval,
    into,
    is,
    isolation,
    json,
    jsonb,
    key,
    last,
    level,
    like,
    limit,
    local,
    locked,
    name,
    not,
    nowait,
    @"null",
    nullif,
    nulls,
    numeric,
    oid,
    @"or",
    order,
    precision,
    primary,
    read,
    real,
    release,
    repeatable,
    reset,
    rollback,
    savepoint,
    select,
    serializable,
    session,
    set,
    share,
    show,
    skip,
    smallint,
    start,
    table,
    text,
    then,
    time,
    timestamp,
    timestamptz,
    to,
    transaction,
    @"true",
    uncommitted,
    unknown,
    update,
    values,
    when,
    where,
    with,
    without,
    work,
    zone,
    // Query clauses (design §4.9).
    group,
    having,
    distinct,
    on,
    join,
    inner,
    left,
    right,
    full,
    outer,
    cross,
    using,
    natural,
    recursive,
    @"union",
    intersect,
    except,
    offset,
    fetch,
    next,
    row,
    rows,
    only,
    exists,
    filter,
    window,
    lateral,
    // DML, defaults, identity and sequences (design §5.10-§5.13).
    returning,
    conflict,
    do,
    nothing,
    constraint,
    sequence,
    increment,
    minvalue,
    maxvalue,
    cycle,
    cache,
    generated,
    always,
    identity,
    overriding,
    system,
    stored,
    no,
    user,
    value,
    regclass,
    regtype,
    greatest,
    least,
    any,
    some,
    symmetric,
    asymmetric,
};

/// Words that cannot be unquoted identifiers.
pub fn reserved(keyword: Keyword) bool {
    return switch (keyword) {
        .create, .drop, .insert, .select, .update, .delete, .table, .into, .values, .from, .where, .@"and", .@"or", .set, .order, .by, .asc, .desc, .limit, .is, .not, .@"null", .@"true", .@"false", .primary, .key, .case, .when, .then, .@"else", .end, .cast, .as, .in, .between, .like, .ilike, .@"for" => true,
        // PostgreSQL reserved and type_func_name keywords used by queries.
        .group, .having, .distinct, .on, .join, .inner, .left, .right, .full, .outer, .cross, .using, .natural, .@"union", .intersect, .except, .offset, .fetch, .only, .with, .all, .window, .lateral => true,
        .returning, .do, .constraint, .default, .any, .some, .symmetric, .asymmetric => true,
        else => false,
    };
}

pub fn keywordOf(comptime text: []const u8) Keyword {
    comptime {
        var name: [text.len]u8 = undefined;
        for (text, 0..) |byte, index| name[index] = types.lower(byte);
        const final = name;
        return @field(Keyword, &final);
    }
}

pub fn classify(word: []const u8) Keyword {
    if (word.len < 2 or word.len > 12) return .none;
    var name: [12]u8 = undefined;
    for (word, 0..) |byte, index| name[index] = types.lower(byte);
    // Only keywords of the word's length are compared (bucketed at comptime).
    switch (word.len) {
        inline 2...12 => |length| {
            @setEvalBranchQuota(20000);
            const wanted = name[0..length];
            inline for (@typeInfo(Keyword).@"enum".field_names) |field| {
                if (comptime field.len == length) {
                    if (types.same(field, wanted)) return @field(Keyword, field);
                }
            }
        },
        else => {},
    }
    return .none;
}

pub const Symbol = enum {
    none,
    comma,
    lparen,
    rparen,
    semicolon,
    dot,
    star,
    plus,
    minus,
    slash,
    percent,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    concat,
    cast,
    arrow,
    arrow_text,
    path,
    path_text,
    contains,
    contained,
    question,
};

pub const Token = struct {
    kind: Kind = .end,
    symbol: Symbol = .none,
    keyword: Keyword = .none,
    /// Raw span; for quoted forms it excludes the quotes.
    start: usize = 0,
    end: usize = 0,
    /// Decoded length (quoted forms) or raw length.
    len: usize = 0,
    /// Integer literal magnitude or parameter number.
    integer: u64 = 0,

    pub fn raw(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn quoted(self: Token) Quoted {
        return .{ .start = self.start, .end = self.end, .len = self.len };
    }

    pub fn isWord(self: Token, comptime expected: []const u8) bool {
        return self.keyword == comptime keywordOf(expected);
    }
};

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

pub const Tokenizer = struct {
    source: []const u8,
    position: usize = 0,
    /// Decoded string literals beyond this raise TextCapacity.
    text_limit: usize,

    fn skip(self: *Tokenizer) Error!void {
        const source = self.source;
        while (self.position < source.len) {
            const byte = source[self.position];
            if (space(byte)) {
                self.position += 1;
            } else if (byte == '-' and self.position + 1 < source.len and source[self.position + 1] == '-') {
                self.position += 2;
                while (self.position < source.len and source[self.position] != '\n') self.position += 1;
            } else if (byte == '/' and self.position + 1 < source.len and source[self.position + 1] == '*') {
                // PostgreSQL block comments nest.
                self.position += 2;
                var depth: usize = 1;
                while (depth != 0) {
                    if (self.position + 1 >= source.len) return error.Syntax;
                    if (source[self.position] == '/' and source[self.position + 1] == '*') {
                        depth += 1;
                        self.position += 2;
                    } else if (source[self.position] == '*' and source[self.position + 1] == '/') {
                        depth -= 1;
                        self.position += 2;
                    } else self.position += 1;
                }
            } else break;
        }
    }

    fn quotedForm(self: *Tokenizer, quote: u8, limit: usize, overflow: Error) Error!Token {
        const start = self.position;
        var len: usize = 0;
        while (self.position < self.source.len) {
            const byte = self.source[self.position];
            self.position += 1;
            if (byte == quote) {
                if (self.position == self.source.len or self.source[self.position] != quote)
                    return .{ .start = start, .end = self.position - 1, .len = len };
                self.position += 1;
            }
            if (len == limit) return overflow;
            len += 1;
        }
        return error.Syntax;
    }

    fn number(self: *Tokenizer) Error!Token {
        const source = self.source;
        const start = self.position;
        var token: Token = .{ .kind = .integer, .start = start };
        var magnitude: u64 = 0;
        var overflow = false;
        while (self.position < source.len and types.digit(source[self.position])) : (self.position += 1) {
            const digit_value: u64 = source[self.position] - '0';
            if (magnitude > (18446744073709551615 - digit_value) / 10) overflow = true else magnitude = magnitude * 10 + digit_value;
        }
        if (self.position < source.len and source[self.position] == '.') {
            token.kind = .decimal;
            self.position += 1;
            while (self.position < source.len and types.digit(source[self.position])) self.position += 1;
        }
        if (self.position == start + 1 and token.kind == .decimal) return error.Syntax;
        if (self.position < source.len and (source[self.position] == 'e' or source[self.position] == 'E')) {
            const mark = self.position;
            self.position += 1;
            if (self.position < source.len and (source[self.position] == '+' or source[self.position] == '-')) self.position += 1;
            if (self.position < source.len and types.digit(source[self.position])) {
                token.kind = .decimal;
                while (self.position < source.len and types.digit(source[self.position])) self.position += 1;
            } else self.position = mark;
        }
        // Trailing junk after a numeric literal is a syntax error.
        if (self.position < source.len and types.letter(source[self.position])) return error.Syntax;
        if (token.kind == .integer and overflow) token.kind = .decimal;
        token.integer = magnitude;
        token.end = self.position;
        token.len = token.end - start;
        return token;
    }

    pub fn next(self: *Tokenizer) Error!Token {
        try self.skip();
        const source = self.source;
        const start = self.position;
        if (start == source.len) return .{ .kind = .end, .start = start, .end = start };
        const byte = source[start];
        if (types.letter(byte)) {
            self.position += 1;
            while (self.position < source.len and (types.letter(source[self.position]) or types.digit(source[self.position]) or source[self.position] == '$')) self.position += 1;
            return .{ .kind = .word, .keyword = classify(source[start..self.position]), .start = start, .end = self.position, .len = self.position - start };
        }
        if (types.digit(byte) or (byte == '.' and start + 1 < source.len and types.digit(source[start + 1]))) return self.number();
        if (byte == '\'') {
            self.position += 1;
            var token = try self.quotedForm('\'', self.text_limit, error.TextCapacity);
            token.kind = .string;
            return token;
        }
        if (byte == '"') {
            self.position += 1;
            var token = try self.quotedForm('"', 255, error.NameCapacity);
            if (token.len == 0) return error.Syntax;
            token.kind = .quoted_word;
            return token;
        }
        if (byte == '$') {
            self.position += 1;
            var value: u64 = 0;
            while (self.position < source.len and types.digit(source[self.position])) : (self.position += 1) {
                value = value * 10 + (source[self.position] - '0');
                if (value > 65535) return error.Syntax;
            }
            if (self.position == start + 1 or value == 0) return error.Syntax;
            if (self.position < source.len and types.letter(source[self.position])) return error.Syntax;
            return .{ .kind = .parameter, .start = start, .end = self.position, .len = self.position - start, .integer = value };
        }
        const following: u8 = if (start + 1 < source.len) source[start + 1] else 0;
        const third: u8 = if (start + 2 < source.len) source[start + 2] else 0;
        var width: usize = 1;
        const symbol: Symbol = switch (byte) {
            ',' => .comma,
            '(' => .lparen,
            ')' => .rparen,
            ';' => .semicolon,
            '.' => .dot,
            '*' => .star,
            '+' => .plus,
            '/' => .slash,
            '%' => .percent,
            '=' => .eq,
            '?' => .question,
            '-' => if (following == '>') blk: {
                width = if (third == '>') 3 else 2;
                break :blk if (third == '>') Symbol.arrow_text else Symbol.arrow;
            } else .minus,
            '<' => if (following == '=') blk: {
                width = 2;
                break :blk Symbol.le;
            } else if (following == '>') blk: {
                width = 2;
                break :blk Symbol.ne;
            } else if (following == '@') blk: {
                width = 2;
                break :blk Symbol.contained;
            } else .lt,
            '>' => if (following == '=') blk: {
                width = 2;
                break :blk Symbol.ge;
            } else .gt,
            '!' => if (following == '=') blk: {
                width = 2;
                break :blk Symbol.ne;
            } else return error.Syntax,
            '|' => if (following == '|') blk: {
                width = 2;
                break :blk Symbol.concat;
            } else return error.Syntax,
            ':' => if (following == ':') blk: {
                width = 2;
                break :blk Symbol.cast;
            } else return error.Syntax,
            '#' => if (following == '>') blk: {
                width = if (third == '>') 3 else 2;
                break :blk if (third == '>') Symbol.path_text else Symbol.path;
            } else return error.Syntax,
            '@' => if (following == '>') blk: {
                width = 2;
                break :blk Symbol.contains;
            } else return error.Syntax,
            else => return error.Syntax,
        };
        self.position += width;
        return .{ .kind = .symbol, .symbol = symbol, .start = start, .end = self.position, .len = width };
    }
};

/// Frozen alpha-grammar byte lexer: whitespace and `--` comments separate
/// tokens; words are ASCII letters, digits and `_`; `''` escapes quotes.
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

/// Copies a quoted literal's decoded bytes into `out` (len bytes). `quote`
/// is the doubled delimiter (`'` for strings, `"` for identifiers).
pub fn decodeQuotedWith(source: []const u8, quoted: Quoted, quote: u8, out: []u8) void {
    var index = quoted.start;
    var written: usize = 0;
    while (index < quoted.end) {
        out[written] = source[index];
        written += 1;
        index += if (source[index] == quote) 2 else 1;
    }
}

pub fn decodeQuoted(source: []const u8, quoted: Quoted, out: []u8) void {
    decodeQuotedWith(source, quoted, '\'', out);
}
