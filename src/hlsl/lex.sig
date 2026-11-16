//! @zpm/hlsl lex — HLSL's tokens: identifiers, numbers, strings and C's
//! punctuators. A token's text lives in the compiler's text pool (every
//! source, include and macro-made text is copied there once), so a token
//! is four words and nothing else is kept.

const std = @import("std");

pub const Kind = enum(u8) {
    eof,
    /// the end of a line (the preprocessor's; never reaches the parser)
    newline,
    ident,
    int_lit,
    float_lit,
    string,
    /// a #include's <file name>
    angled,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    dot,
    comma,
    colon,
    coloncolon,
    semicolon,
    question,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    tilde,
    amp,
    pipe,
    caret,
    lt,
    gt,
    assign,
    inc,
    dec,
    shl,
    shr,
    le,
    ge,
    eq,
    ne,
    and_and,
    or_or,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    mod_assign,
    shl_assign,
    shr_assign,
    and_assign,
    xor_assign,
    or_assign,
    hash,
    hash_hash,
    /// `#pragma pack_matrix(row_major)` and `(column_major)`, passed on to
    /// the parser by the preprocessor
    pragma_row_major,
    pragma_column_major,
    /// a character HLSL has no use for
    bad,
};

pub const Token = struct {
    /// its text: pool[off..][0..len]
    off: u32 = 0,
    len: u16 = 0,
    kind: Kind = .eof,
    flags: u8 = 0,
    /// its line (low 24 bits) and file (high 8)
    pos: u32 = 0,

    pub fn line(t: Token) u32 {
        return t.pos & 0xff_ffff;
    }
    pub fn file(t: Token) u8 {
        return @truncate(t.pos >> 24);
    }
};

/// The first token on its line (a `#` there starts a directive).
pub const BOL: u8 = 1;
/// Whitespace before it (for stringizing).
pub const SPACE: u8 = 2;
/// Not to be expanded again (a macro's name met inside its own expansion).
pub const NOEXPAND: u8 = 4;

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Lexes `text` (at `base` in the pool) into `out`, newline tokens at line
/// ends; comments and line splices skipped. Returns the count, or null when
/// `out` is too small.
pub fn lex(text: []const u8, base: u32, file: u8, first_line: u32, out: []Token) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    var line: u32 = first_line;
    var bol = true;
    var space = false;
    while (true) {
        // whitespace, comments, splices
        while (i < text.len) {
            const c = text[i];
            if (c == ' ' or c == '\t' or c == '\r' or c == 0x0b or c == 0x0c) {
                i += 1;
                space = true;
            } else if (c == '\\' and i + 1 < text.len and (text[i + 1] == '\n' or (text[i + 1] == '\r' and i + 2 < text.len and text[i + 2] == '\n'))) {
                i += if (text[i + 1] == '\r') 3 else 2;
                line += 1;
            } else if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') {
                    // (a spliced line comment goes on)
                    if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '\n') {
                        i += 1;
                        line += 1;
                    }
                    i += 1;
                }
            } else if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
                i += 2;
                while (i < text.len and !(text[i] == '*' and i + 1 < text.len and text[i + 1] == '/')) {
                    if (text[i] == '\n') line += 1;
                    i += 1;
                }
                i = @min(i + 2, text.len);
                space = true;
            } else break;
        }
        if (n + 2 > out.len) return null;
        const pos = (line & 0xff_ffff) | (@as(u32, file) << 24);
        if (i >= text.len) {
            out[n] = .{ .off = base + @as(u32, @intCast(i)), .kind = .newline, .pos = pos };
            out[n + 1] = .{ .off = base + @as(u32, @intCast(i)), .kind = .eof, .pos = pos };
            return n + 2;
        }
        const start = i;
        const c = text[i];
        var kind: Kind = .bad;
        if (c == '\n') {
            i += 1;
            kind = .newline;
        } else if (isIdentStart(c)) {
            while (i < text.len and isIdent(text[i])) i += 1;
            kind = .ident;
        } else if (std.ascii.isDigit(c) or (c == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            kind = number(text, &i);
        } else if (c == '"') {
            i += 1;
            while (i < text.len and text[i] != '"' and text[i] != '\n') {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
                i += 1;
            }
            if (i < text.len and text[i] == '"') i += 1;
            kind = .string;
        } else {
            kind = punct(text, &i);
        }
        out[n] = .{
            .off = base + @as(u32, @intCast(start)),
            .len = @intCast(@min(i - start, 0xffff)),
            .kind = kind,
            .flags = (if (bol) BOL else 0) | (if (space) SPACE else 0),
            .pos = pos,
        };
        n += 1;
        if (kind == .newline) {
            line += 1;
            bol = true;
        } else bol = false;
        space = false;
    }
}

fn number(text: []const u8, i: *usize) Kind {
    var j = i.*;
    var kind: Kind = .int_lit;
    if (text[j] == '0' and j + 1 < text.len and (text[j + 1] == 'x' or text[j + 1] == 'X')) {
        j += 2;
        while (j < text.len and std.ascii.isHex(text[j])) j += 1;
    } else {
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        if (j < text.len and text[j] == '.') {
            kind = .float_lit;
            j += 1;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        }
        if (j < text.len and (text[j] == 'e' or text[j] == 'E')) {
            var k = j + 1;
            if (k < text.len and (text[k] == '+' or text[k] == '-')) k += 1;
            if (k < text.len and std.ascii.isDigit(text[k])) {
                kind = .float_lit;
                j = k;
                while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            }
        }
    }
    // suffixes: u, l, f, h, lf (any case)
    while (j < text.len and isIdent(text[j])) {
        const s = std.ascii.toLower(text[j]);
        if (s == 'f' or s == 'h') kind = .float_lit;
        j += 1;
    }
    i.* = j;
    return kind;
}

fn punct(text: []const u8, i: *usize) Kind {
    const c = text[i.*];
    const c1: u8 = if (i.* + 1 < text.len) text[i.* + 1] else 0;
    const c2: u8 = if (i.* + 2 < text.len) text[i.* + 2] else 0;
    var len: usize = 1;
    const k: Kind = switch (c) {
        '(' => .lparen,
        ')' => .rparen,
        '[' => .lbracket,
        ']' => .rbracket,
        '{' => .lbrace,
        '}' => .rbrace,
        '.' => .dot,
        ',' => .comma,
        ';' => .semicolon,
        '?' => .question,
        '~' => .tilde,
        ':' => if (c1 == ':') blk: {
            len = 2;
            break :blk .coloncolon;
        } else .colon,
        '#' => if (c1 == '#') blk: {
            len = 2;
            break :blk .hash_hash;
        } else .hash,
        '+' => if (c1 == '+') l2(&len, .inc) else if (c1 == '=') l2(&len, .add_assign) else .plus,
        '-' => if (c1 == '-') l2(&len, .dec) else if (c1 == '=') l2(&len, .sub_assign) else .minus,
        '*' => if (c1 == '=') l2(&len, .mul_assign) else .star,
        '/' => if (c1 == '=') l2(&len, .div_assign) else .slash,
        '%' => if (c1 == '=') l2(&len, .mod_assign) else .percent,
        '!' => if (c1 == '=') l2(&len, .ne) else .bang,
        '=' => if (c1 == '=') l2(&len, .eq) else .assign,
        '^' => if (c1 == '=') l2(&len, .xor_assign) else .caret,
        '&' => if (c1 == '&') l2(&len, .and_and) else if (c1 == '=') l2(&len, .and_assign) else .amp,
        '|' => if (c1 == '|') l2(&len, .or_or) else if (c1 == '=') l2(&len, .or_assign) else .pipe,
        '<' => if (c1 == '<') (if (c2 == '=') l3(&len, .shl_assign) else l2(&len, .shl)) else if (c1 == '=') l2(&len, .le) else .lt,
        '>' => if (c1 == '>') (if (c2 == '=') l3(&len, .shr_assign) else l2(&len, .shr)) else if (c1 == '=') l2(&len, .ge) else .gt,
        else => .bad,
    };
    i.* += len;
    return k;
}

fn l2(len: *usize, k: Kind) Kind {
    len.* = 2;
    return k;
}

fn l3(len: *usize, k: Kind) Kind {
    len.* = 3;
    return k;
}

/// A punctuator's spelling (for stringizing and messages).
pub fn spelling(k: Kind) []const u8 {
    return switch (k) {
        .lparen => "(",
        .rparen => ")",
        .lbracket => "[",
        .rbracket => "]",
        .lbrace => "{",
        .rbrace => "}",
        .dot => ".",
        .comma => ",",
        .colon => ":",
        .coloncolon => "::",
        .semicolon => ";",
        .question => "?",
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .bang => "!",
        .tilde => "~",
        .amp => "&",
        .pipe => "|",
        .caret => "^",
        .lt => "<",
        .gt => ">",
        .assign => "=",
        .inc => "++",
        .dec => "--",
        .shl => "<<",
        .shr => ">>",
        .le => "<=",
        .ge => ">=",
        .eq => "==",
        .ne => "!=",
        .and_and => "&&",
        .or_or => "||",
        .add_assign => "+=",
        .sub_assign => "-=",
        .mul_assign => "*=",
        .div_assign => "/=",
        .mod_assign => "%=",
        .shl_assign => "<<=",
        .shr_assign => ">>=",
        .and_assign => "&=",
        .xor_assign => "^=",
        .or_assign => "|=",
        .hash => "#",
        .hash_hash => "##",
        .eof => "end of file",
        .newline => "end of line",
        else => "?",
    };
}

/// An integer literal's value (decimal, hex, or C's octal), its suffixes
/// ignored; `unsigned` set by a u suffix.
pub fn intValue(s: []const u8, unsigned: *bool) u64 {
    var end = s.len;
    unsigned.* = false;
    while (end > 0 and std.ascii.isAlphabetic(s[end - 1]) and !(s.len > 2 and (s[1] == 'x' or s[1] == 'X') and std.ascii.isHex(s[end - 1]))) {
        if (s[end - 1] == 'u' or s[end - 1] == 'U') unsigned.* = true;
        end -= 1;
    }
    const d = s[0..end];
    var v: u64 = 0;
    if (d.len > 2 and d[0] == '0' and (d[1] == 'x' or d[1] == 'X')) {
        for (d[2..]) |ch| v = (v << 4) | (std.fmt.charToDigit(ch, 16) catch 0);
    } else if (d.len > 1 and d[0] == '0') {
        for (d[1..]) |ch| v = v * 8 + (std.fmt.charToDigit(ch, 8) catch 0);
    } else {
        for (d) |ch| v = v *% 10 +% (std.fmt.charToDigit(ch, 10) catch 0);
    }
    return v;
}

/// A float literal's value (suffixes f, h, l, lf dropped).
pub fn floatValue(s: []const u8) f64 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == 'f' or s[end - 1] == 'F' or s[end - 1] == 'h' or s[end - 1] == 'H' or s[end - 1] == 'l' or s[end - 1] == 'L')) end -= 1;
    var buf: [64]u8 = undefined;
    var d = s[0..end];
    // ("1." and ".5" are fine for parseFloat; "1.e3" is not)
    if (d.len < buf.len) {
        var n: usize = 0;
        for (d, 0..) |ch, k| {
            buf[n] = ch;
            n += 1;
            if (ch == '.' and (k + 1 == d.len or !std.ascii.isDigit(d[k + 1]))) {
                buf[n] = '0';
                n += 1;
            }
        }
        d = buf[0..n];
    }
    return std.fmt.parseFloat(f64, d) catch 0;
}

test "lexing: punctuators, numbers, comments, lines" {
    const src = "float4 x = 1.5f + 0x10u; // c\n/* a\nb */ a <<= b>>c;\n";
    var out: [64]Token = undefined;
    const n = lex(src, 0, 0, 1, &out).?;
    const want = [_]Kind{ .ident, .ident, .assign, .float_lit, .plus, .int_lit, .semicolon, .newline, .ident, .shl_assign, .ident, .shr, .ident, .semicolon, .newline, .newline, .eof };
    var kinds: [64]Kind = undefined;
    for (out[0..n], 0..) |t, k| kinds[k] = t.kind;
    try std.testing.expectEqualSlices(Kind, &want, kinds[0..n]);
    try std.testing.expectEqual(@as(u32, 3), out[8].line());
    var u = false;
    try std.testing.expectEqual(@as(u64, 16), intValue("0x10u", &u));
    try std.testing.expect(u);
    try std.testing.expectEqual(@as(f64, 1.5), floatValue("1.5f"));
    try std.testing.expectEqual(@as(f64, 1000), floatValue("1.e3"));
}
