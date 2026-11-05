//! SQL lexers (Layer 0). Callers keep `source` alive for the statement; spans
//! index into it.
//!
//! `Tokenizer` is the statement-pipeline lexer (design §4.1): words (ASCII
//! case-folded on comparison), double-quoted identifiers that keep their case
//! (`""` escapes), string literals with `''` escaping, integer, decimal and
//! exponent literals, `$n` placeholders, the operators
//! `= <> != < <= > >= + - * / % || :: -> ->> #> #>> @> <@ ? & | # << >> ~` and punctuation,
//! with whitespace, `--` and (nested) `/* */` comments between tokens.
//! PostgreSQL's other string forms are string tokens too: `E'...'` escape
//! strings, `$tag$...$tag$` dollar quoting and `U&'...' [UESCAPE 'c']`
//! Unicode-escape strings. They are fully validated here (22025, 22021 or
//! 42601, as scan.l/parser.c report them); `decodeQuoted` cannot fail later.
//!
//! `Lexer` is the frozen byte-level lexer of the alpha grammar. Only the
//! `legacy_alpha` recognizer (alpha.sig) uses it; it must never grow.
const types = @import("types.sig");
const Error = types.Error;

/// How a string token's raw span decodes.
pub const QuoteForm = enum(u8) { standard, escape, dollar, unicode };

pub const Quoted = struct {
    /// First raw byte after the opening quote.
    start: usize,
    /// Raw byte index of the closing quote.
    end: usize,
    /// Decoded length after collapsing the doubled quote.
    len: usize,
    /// `''` doubling, E'' backslash escapes, verbatim dollar quoting or U&''.
    form: QuoteForm = .standard,
    /// The U&'' escape character (UESCAPE); backslash by default.
    escape: u8 = '\\',
};

pub const Kind = enum { end, word, quoted_word, string, integer, decimal, parameter, symbol };

/// Words the parser recognizes, classified once per token (quoted words are
/// never keywords).
pub const Keyword = enum {
    none,
    rollup, over, partition, current, preceding, following, unbounded, range, groups,
    exclude, others, ties,
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
    // Character types (B11 types lane).
    varchar,
    character,
    char,
    varying,
    bpchar,
    uuid,
    bytea,
    timetz,
    bit,
    varbit,
    money,
    // Advanced types (B11 advanced types lane).
    pg_lsn,
    xid8,
    int4range,
    int8range,
    numrange,
    daterange,
    tsrange,
    tstzrange,
    inet,
    cidr,
    macaddr,
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
    // Bitwise integer operators (B11): & | # << >> and prefix ~.
    ampersand,
    pipe,
    hash,
    shift_left,
    shift_right,
    tilde,
    // Arrays and ranges (B11 advanced types): [ ] : and &&.
    lbracket,
    rbracket,
    colon,
    overlap,
    // Ranges: &< &> -|-.
    over_left,
    over_right,
    adjacent,
    // Networks: <<= and >>=.
    within_eq,
    contains_eq,
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
    /// String decoding form and U&'' escape character.
    form: QuoteForm = .standard,
    escape: u8 = '\\',
    /// Delimiter bytes before `start` and after `end` (quoted forms only):
    /// `'x'` is 1/1, `E'x'` 2/1, `$q$x$q$` 3/3, `U&'x' UESCAPE '!'` 3/13.
    prefix: usize = 0,
    suffix: usize = 0,

    pub fn raw(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn quoted(self: Token) Quoted {
        return .{ .start = self.start, .end = self.end, .len = self.len, .form = self.form, .escape = self.escape };
    }

    /// The whole token as written, including its delimiters.
    pub fn whole(self: Token, source: []const u8) []const u8 {
        return source[self.start - self.prefix .. self.end + self.suffix];
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
            if (byte == 0 and quote == '"') return error.Syntax;
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

    fn sized(self: *const Tokenizer, len: usize) Error!usize {
        if (len > self.text_limit) return error.TextCapacity;
        return len;
    }

    /// `E'...'`: `\'` and `''` quote; the escapes are validated now.
    fn escapeString(self: *Tokenizer) Error!Token {
        const source = self.source;
        const start = self.position + 2;
        var at = start;
        while (true) {
            if (at >= source.len) return error.Syntax;
            if (source[at] == '\\') {
                at += 2;
            } else if (source[at] == '\'') {
                if (at + 1 < source.len and source[at + 1] == '\'') at += 2 else break;
            } else at += 1;
        }
        const len = try self.sized(try decodeEscape(source[start..at], null));
        self.position = at + 1;
        return .{ .kind = .string, .form = .escape, .start = start, .end = at, .len = len, .prefix = 2, .suffix = 1 };
    }

    /// `$tag$...$tag$` (dollar quoting): verbatim content. A `$` that does
    /// not open a delimiter is not a token (PostgreSQL's dolqfailed).
    fn dollarString(self: *Tokenizer) Error!Token {
        const source = self.source;
        const open = self.position;
        var at = open + 1;
        if (at < source.len and dollarStart(source[at])) {
            at += 1;
            while (at < source.len and (dollarStart(source[at]) or types.digit(source[at]))) at += 1;
        }
        if (at >= source.len or source[at] != '$') return error.Syntax;
        const delimiter = source[open .. at + 1];
        const start = at + 1;
        var scan = start;
        while (scan + delimiter.len <= source.len) : (scan += 1) {
            if (source[scan] == '$' and types.same(source[scan..][0..delimiter.len], delimiter)) {
                const len = try self.sized(scan - start);
                self.position = scan + delimiter.len;
                return .{ .kind = .string, .form = .dollar, .start = start, .end = scan, .len = len, .prefix = delimiter.len, .suffix = delimiter.len };
            }
        }
        return error.Syntax;
    }

    /// `U&'...'` with an optional `UESCAPE 'c'` clause (parser.c).
    fn unicodeString(self: *Tokenizer) Error!Token {
        self.position += 3;
        var token = try self.quotedForm('\'', self.source.len, error.TextCapacity);
        token.kind = .string;
        token.form = .unicode;
        token.prefix = 3;
        token.suffix = 1;
        const after = self.position;
        var escape: u8 = '\\';
        try self.skip();
        const word_start = self.position;
        while (self.position < self.source.len and (types.letter(self.source[self.position]) or types.digit(self.source[self.position]) or self.source[self.position] == '$')) self.position += 1;
        if (types.keyword(self.source[word_start..self.position], "uescape")) {
            try self.skip();
            // UESCAPE takes a plain string constant (never another U&'').
            const lead = if (self.position < self.source.len) self.source[self.position] else 0;
            if ((lead == 'u' or lead == 'U') and self.position + 1 < self.source.len and self.source[self.position + 1] == '&') return error.Syntax;
            const literal = try self.next();
            if (literal.kind != .string or literal.len != 1) return error.Syntax;
            var byte: [1]u8 = undefined;
            decodeQuoted(self.source, literal.quoted(), &byte);
            if (!uescapeCharacter(byte[0])) return error.Syntax;
            escape = byte[0];
            token.suffix = self.position - token.end;
        } else self.position = after;
        token.escape = escape;
        token.len = try self.sized(try decodeUnicode(self.source[token.start..token.end], escape, null));
        return token;
    }

    pub fn next(self: *Tokenizer) Error!Token {
        try self.skip();
        const source = self.source;
        const start = self.position;
        if (start == source.len) return .{ .kind = .end, .start = start, .end = start };
        const byte = source[start];
        if ((byte == 'e' or byte == 'E') and start + 1 < source.len and source[start + 1] == '\'') return self.escapeString();
        if ((byte == 'u' or byte == 'U') and start + 2 < source.len and source[start + 1] == '&') {
            if (source[start + 2] == '\'') return self.unicodeString();
            // U&"..." Unicode identifiers are not supported (never `U & "x"`).
            if (source[start + 2] == '"') return error.Syntax;
        }
        if (byte == '$' and start + 1 < source.len and !types.digit(source[start + 1])) return self.dollarString();
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
            token.prefix = 1;
            token.suffix = 1;
            return token;
        }
        if (byte == '"') {
            self.position += 1;
            var token = try self.quotedForm('"', 255, error.NameCapacity);
            if (token.len == 0) return error.Syntax;
            token.kind = .quoted_word;
            token.prefix = 1;
            token.suffix = 1;
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
            } else if (following == '|' and third == '-') blk: {
                width = 3;
                break :blk Symbol.adjacent;
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
            } else if (following == '<') blk: {
                width = if (third == '=') 3 else 2;
                break :blk if (third == '=') Symbol.within_eq else Symbol.shift_left;
            } else .lt,
            '>' => if (following == '=') blk: {
                width = 2;
                break :blk Symbol.ge;
            } else if (following == '>') blk: {
                width = if (third == '=') 3 else 2;
                break :blk if (third == '=') Symbol.contains_eq else Symbol.shift_right;
            } else .gt,
            '!' => if (following == '=') blk: {
                width = 2;
                break :blk Symbol.ne;
            } else return error.Syntax,
            '|' => if (following == '|') blk: {
                width = 2;
                break :blk Symbol.concat;
            } else .pipe,
            '&' => if (following == '&') blk: {
                width = 2;
                break :blk Symbol.overlap;
            } else if (following == '<') blk: {
                width = 2;
                break :blk Symbol.over_left;
            } else if (following == '>') blk: {
                width = 2;
                break :blk Symbol.over_right;
            } else .ampersand,
            '[' => .lbracket,
            ']' => .rbracket,
            '~' => .tilde,
            ':' => if (following == ':') blk: {
                width = 2;
                break :blk Symbol.cast;
            } else .colon,
            '#' => if (following == '>') blk: {
                width = if (third == '>') 3 else 2;
                break :blk if (third == '>') Symbol.path_text else Symbol.path;
            } else .hash,
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

/// Copies a string literal's decoded bytes (`quoted.len` of them) into
/// `out`, according to its form. The tokenizer validated the literal.
pub fn decodeQuoted(source: []const u8, quoted: Quoted, out: []u8) void {
    const raw = source[quoted.start..quoted.end];
    switch (quoted.form) {
        .standard => decodeQuotedWith(source, quoted, '\'', out),
        .dollar => @memcpy(out[0..raw.len], raw),
        .escape => _ = decodeEscape(raw, out[0..quoted.len]) catch {},
        .unicode => _ = decodeUnicode(raw, quoted.escape, out[0..quoted.len]) catch {},
    }
}

/// scan.l dolq_start: a letter, `_` or any non-ASCII byte.
fn dollarStart(byte: u8) bool {
    return types.letter(byte) or byte >= 0x80;
}

fn hexValue(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

/// parser.c check_uescapechar.
fn uescapeCharacter(byte: u8) bool {
    return hexValue(byte) == null and byte != '+' and byte != '\'' and byte != '"' and
        byte != ' ' and byte != '\t' and byte != '\n' and byte != '\r' and byte != 0x0b and byte != 0x0c;
}

/// Appends to an optional output, counting the decoded length either way
/// and checking that the decoded bytes form valid UTF-8.
const Sink = struct {
    out: ?[]u8,
    len: usize = 0,
    check: Utf8Check = .{},

    fn byte(self: *Sink, value: u8) void {
        if (self.out) |buffer| {
            if (self.len < buffer.len) buffer[self.len] = value;
        }
        self.len += 1;
        self.check.feed(value);
    }

    /// pg_unicode_to_server for a UTF-8 database; `code` is a valid scalar.
    fn scalar(self: *Sink, code: u32) void {
        if (code < 0x80) {
            self.byte(@intCast(code));
        } else if (code < 0x800) {
            self.byte(@intCast(0xc0 | (code >> 6)));
            self.byte(@intCast(0x80 | (code & 0x3f)));
        } else if (code < 0x10000) {
            self.byte(@intCast(0xe0 | (code >> 12)));
            self.byte(@intCast(0x80 | ((code >> 6) & 0x3f)));
            self.byte(@intCast(0x80 | (code & 0x3f)));
        } else {
            self.byte(@intCast(0xf0 | (code >> 18)));
            self.byte(@intCast(0x80 | ((code >> 12) & 0x3f)));
            self.byte(@intCast(0x80 | ((code >> 6) & 0x3f)));
            self.byte(@intCast(0x80 | (code & 0x3f)));
        }
    }
};

/// Streaming pg_utf8_islegal: NUL, overlong forms, surrogates and values
/// above U+10FFFF are invalid.
pub const Utf8Check = struct {
    need: u8 = 0,
    low: u8 = 0x80,
    high: u8 = 0xbf,
    valid: bool = true,

    pub fn feed(self: *Utf8Check, byte: u8) void {
        if (self.need != 0) {
            if (byte < self.low or byte > self.high) self.valid = false;
            self.need -= 1;
            self.low = 0x80;
            self.high = 0xbf;
            return;
        }
        switch (byte) {
            0 => self.valid = false,
            0x01...0x7f => {},
            0xc2...0xdf => self.need = 1,
            0xe0 => { self.need = 2; self.low = 0xa0; },
            0xe1...0xec, 0xee, 0xef => self.need = 2,
            0xed => { self.need = 2; self.high = 0x9f; },
            0xf0 => { self.need = 3; self.low = 0x90; },
            0xf1...0xf3 => self.need = 3,
            0xf4 => { self.need = 3; self.high = 0x8f; },
            else => self.valid = false,
        }
    }

    pub fn finish(self: *const Utf8Check) bool {
        return self.valid and self.need == 0;
    }
};

fn surrogateFirst(code: u32) bool {
    return code >= 0xd800 and code <= 0xdbff;
}

fn surrogateSecond(code: u32) bool {
    return code >= 0xdc00 and code <= 0xdfff;
}

fn validScalarValue(code: u32) bool {
    return code > 0 and code <= 0x10ffff;
}

fn hexDigits(raw: []const u8, at: usize, count: usize) ?u32 {
    if (at + count > raw.len) return null;
    var value: u32 = 0;
    for (raw[at..][0..count]) |byte| value = value * 16 + (hexValue(byte) orelse return null);
    return value;
}

/// E'' content (scan.l xe state): `''`, `\b \f \n \r \t \v`, octal `\ooo`,
/// hex `\xhh`, `\uXXXX`, `\UXXXXXXXX` and `\c`. A malformed Unicode escape
/// is 22025; an invalid code point or surrogate pair 42601; and when an
/// escape produced NUL or a high-bit byte the result must be valid UTF-8
/// (pg_verifymbstr, 22021). Returns the decoded length.
pub fn decodeEscape(raw: []const u8, out: ?[]u8) Error!usize {
    var sink: Sink = .{ .out = out };
    var non_ascii = false;
    var pair: u32 = 0;
    var at: usize = 0;
    while (at < raw.len) {
        const byte = raw[at];
        // A high surrogate must be followed directly by its low surrogate.
        if (pair != 0 and !(byte == '\\' and at + 1 < raw.len and (raw[at + 1] == 'u' or raw[at + 1] == 'U'))) return error.Syntax;
        if (byte == '\'') {
            sink.byte('\'');
            at += 2;
            continue;
        }
        if (byte != '\\' or at + 1 >= raw.len) {
            sink.byte(byte);
            at += 1;
            continue;
        }
        const kind = raw[at + 1];
        switch (kind) {
            'b' => sink.byte(0x08),
            'f' => sink.byte(0x0c),
            'n' => sink.byte('\n'),
            'r' => sink.byte('\r'),
            't' => sink.byte('\t'),
            'v' => sink.byte(0x0b),
            '0'...'7' => {
                var value: u32 = 0;
                var count: usize = 0;
                while (count < 3 and at + 1 + count < raw.len and raw[at + 1 + count] >= '0' and raw[at + 1 + count] <= '7') : (count += 1) value = value * 8 + (raw[at + 1 + count] - '0');
                const decoded: u8 = @truncate(value);
                sink.byte(decoded);
                if (decoded == 0 or decoded >= 0x80) non_ascii = true;
                at += 1 + count;
                continue;
            },
            'x' => if (at + 2 < raw.len and hexValue(raw[at + 2]) != null) {
                var value: u8 = hexValue(raw[at + 2]).?;
                var count: usize = 1;
                if (at + 3 < raw.len) if (hexValue(raw[at + 3])) |digit| {
                    value = value * 16 + digit;
                    count = 2;
                };
                sink.byte(value);
                if (value == 0 or value >= 0x80) non_ascii = true;
                at += 2 + count;
                continue;
            } else sink.byte('x'),
            'u', 'U' => {
                const width: usize = if (kind == 'u') 4 else 8;
                const code = hexDigits(raw, at + 2, width) orelse return error.InvalidEscapeSequence;
                at += 2 + width;
                if (pair != 0) {
                    if (!surrogateSecond(code)) return error.Syntax;
                    sink.scalar(0x10000 + ((pair & 0x3ff) << 10) + (code & 0x3ff));
                    pair = 0;
                } else if (surrogateFirst(code)) {
                    pair = code;
                } else if (surrogateSecond(code) or !validScalarValue(code)) {
                    return error.Syntax;
                } else sink.scalar(code);
                continue;
            },
            else => {
                sink.byte(kind);
                if (kind == 0 or kind >= 0x80) non_ascii = true;
            },
        }
        at += 2;
    }
    if (pair != 0) return error.Syntax;
    if (non_ascii and !sink.check.finish()) return error.CharacterNotInRepertoire;
    return sink.len;
}

/// The standard-string bytes of a U&'' body, collapsing `''`.
const Plain = struct {
    raw: []const u8,
    at: usize = 0,

    fn done(self: *const Plain) bool {
        return self.at >= self.raw.len;
    }

    /// The decoded byte `ahead` positions on, without consuming it.
    fn peek(self: *const Plain, ahead: usize) ?u8 {
        var at = self.at;
        for (0..ahead) |_| {
            if (at >= self.raw.len) return null;
            at += if (self.raw[at] == '\'') 2 else 1;
        }
        return if (at < self.raw.len) self.raw[at] else null;
    }

    fn skip(self: *Plain, count: usize) void {
        for (0..count) |_| {
            if (self.at >= self.raw.len) return;
            self.at += if (self.raw[self.at] == '\'') 2 else 1;
        }
    }
};

/// U&'' content (parser.c str_udeescape): `cc` for the escape itself,
/// `cXXXX` and `c+XXXXXX`; every malformed escape, invalid code point or
/// unpaired surrogate is 42601.
pub fn decodeUnicode(raw: []const u8, escape: u8, out: ?[]u8) Error!usize {
    var sink: Sink = .{ .out = out };
    var plain: Plain = .{ .raw = raw };
    var pair: u32 = 0;
    while (!plain.done()) {
        const byte = plain.peek(0).?;
        if (byte != escape) {
            if (pair != 0) return error.Syntax;
            sink.byte(byte);
            plain.skip(1);
            continue;
        }
        if (plain.peek(1) == escape) {
            if (pair != 0) return error.Syntax;
            sink.byte(escape);
            plain.skip(2);
            continue;
        }
        var code: u32 = 0;
        var width: usize = 4;
        var first: usize = 1;
        if (plain.peek(1) == '+') {
            width = 6;
            first = 2;
        }
        for (0..width) |index| {
            const digit = plain.peek(first + index) orelse return error.Syntax;
            code = code * 16 + (hexValue(digit) orelse return error.Syntax);
        }
        plain.skip(first + width);
        if (!validScalarValue(code)) return error.Syntax;
        if (pair != 0) {
            if (!surrogateSecond(code)) return error.Syntax;
            code = 0x10000 + ((pair & 0x3ff) << 10) + (code & 0x3ff);
            pair = 0;
        } else if (surrogateSecond(code)) return error.Syntax;
        if (surrogateFirst(code)) pair = code else sink.scalar(code);
    }
    if (pair != 0) return error.Syntax;
    return sink.len;
}
