//! @zpm/gfxapi glsl/lex — GLSL ES's tokens (1.00 and 3.00): identifiers,
//! keywords, literals, operators. A token's text is a slice of the source
//! (or of the preprocessor's own text, for `##`); nothing is copied.

const std = @import("std");

pub const Kind = enum(u8) {
    eof,
    ident,
    int_lit,
    uint_lit,
    float_lit,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    dot,
    comma,
    colon,
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
    xor_xor,
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
    /// a character GLSL has no use for (an error where it is read)
    bad,
};

pub const Kw = enum(u8) {
    none,
    // storage, layout, interpolation, precision
    @"const",
    uniform,
    layout,
    centroid,
    flat,
    smooth,
    in,
    out,
    inout,
    attribute,
    varying,
    invariant,
    lowp,
    mediump,
    highp,
    precision,
    // control
    @"break",
    @"continue",
    do,
    @"for",
    @"while",
    @"switch",
    case,
    default,
    @"if",
    @"else",
    discard,
    @"return",
    @"struct",
    true,
    false,
    // types
    void,
    bool,
    int,
    uint,
    float,
    vec2,
    vec3,
    vec4,
    bvec2,
    bvec3,
    bvec4,
    ivec2,
    ivec3,
    ivec4,
    uvec2,
    uvec3,
    uvec4,
    mat2,
    mat3,
    mat4,
    mat2x2,
    mat2x3,
    mat2x4,
    mat3x2,
    mat3x3,
    mat3x4,
    mat4x2,
    mat4x3,
    mat4x4,
    sampler2D,
    sampler3D,
    samplerCube,
    sampler2DShadow,
    samplerCubeShadow,
    sampler2DArray,
    sampler2DArrayShadow,
    isampler2D,
    isampler3D,
    isamplerCube,
    isampler2DArray,
    usampler2D,
    usampler3D,
    usamplerCube,
    usampler2DArray,
    samplerExternalOES,
    /// a word GLSL ES reserves (an error as a name)
    reserved,
};

pub const Token = struct {
    kind: Kind = .eof,
    kw: Kw = .none,
    line: u32 = 0,
    text: []const u8 = "",
};

const reserved_words = [_][]const u8{
    "asm",      "class",     "union",    "enum",          "typedef",  "template",  "this",      "packed",  "resource", "goto",
    "inline",   "noinline",  "public",   "static",        "extern",   "external",  "interface", "long",    "short",    "double",
    "half",     "fixed",     "unsigned", "superp",        "input",    "output",    "hvec2",     "hvec3",   "hvec4",    "dvec2",
    "dvec3",    "dvec4",     "fvec2",    "fvec3",         "fvec4",    "sampler1D", "sampler1DShadow",     "sampler2DRect", "sampler3DRect", "sampler2DRectShadow",
    "sizeof",   "cast",      "namespace", "using",        "volatile", "coherent",  "restrict",  "readonly", "writeonly", "subroutine",
    "common",   "partition", "active",   "filter",        "image2D",  "noperspective", "patch", "sample",  "buffer",
};

/// reserved_words GLSL ES 1.00 does not reserve.
const reserved_300_only = [_][]const u8{
    "resource", "coherent", "restrict", "readonly", "writeonly", "subroutine", "common", "partition",
    "active",   "filter",   "image2D",  "noperspective", "patch", "sample", "buffer",
};

/// A word's keyword, for `version` (100 or 300): a keyword of the other
/// version only is a name there (or reserved: attribute and varying in
/// 3.00).
pub fn keyword(word: []const u8, version: u32) Kw {
    inline for (@typeInfo(Kw).@"enum".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "none") and !std.mem.eql(u8, name, "reserved")) {
            if (std.mem.eql(u8, word, name)) {
                const kw = @field(Kw, name);
                if (version < 300) return switch (kw) {
                    // (3.00's own: names in 1.00)
                    .layout, .centroid, .flat, .smooth, .in, .out, .uint, .uvec2, .uvec3, .uvec4, .mat2x2, .mat2x3, .mat2x4, .mat3x2, .mat3x3, .mat3x4, .mat4x2, .mat4x3, .mat4x4, .sampler3D, .samplerCubeShadow, .sampler2DArray, .sampler2DArrayShadow, .isampler2D, .isampler3D, .isamplerCube, .isampler2DArray, .usampler2D, .usampler3D, .usamplerCube, .usampler2DArray, .@"switch", .case, .default => if (kw == .in or kw == .out) kw else .none,
                    else => kw,
                };
                return switch (kw) {
                    .attribute, .varying => .reserved,
                    else => kw,
                };
            }
        }
    }
    for (reserved_words) |r| {
        if (std.mem.eql(u8, word, r)) {
            // (GLSL ES 3.00's own reserved words are names in 1.00, whose
            // list (1.00.17, 3.7) is the rest: Xwayland's Xv shaders name
            // a float `sample`)
            if (version < 300) {
                for (reserved_300_only) |o| {
                    if (std.mem.eql(u8, word, o)) return .none;
                }
            }
            return .reserved;
        }
    }
    // (names with two underscores in a row, or gl_ ones a shader declares:
    // the parser and checker say so)
    return .none;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Tokens of one line of text (comments already gone), at most out.len.
pub const Lexer = struct {
    src: []const u8,
    at: usize = 0,
    line: u32,

    pub fn next(l: *Lexer) Token {
        while (l.at < l.src.len and (l.src[l.at] == ' ' or l.src[l.at] == '\t' or l.src[l.at] == '\r' or l.src[l.at] == '\x0b' or l.src[l.at] == '\x0c')) l.at += 1;
        if (l.at >= l.src.len) return .{ .kind = .eof, .line = l.line };
        const s = l.src;
        const start = l.at;
        const c = s[start];
        if (isIdentStart(c)) {
            while (l.at < s.len and isIdent(s[l.at])) l.at += 1;
            return .{ .kind = .ident, .line = l.line, .text = s[start..l.at] };
        }
        if (std.ascii.isDigit(c) or (c == '.' and start + 1 < s.len and std.ascii.isDigit(s[start + 1]))) return l.number();
        const two = if (start + 1 < s.len) s[start .. start + 2] else s[start .. start + 1];
        const three = if (start + 2 < s.len) s[start .. start + 3] else two;
        const ops3 = [_]struct { []const u8, Kind }{ .{ "<<=", .shl_assign }, .{ ">>=", .shr_assign } };
        for (ops3) |o| {
            if (std.mem.eql(u8, three, o[0])) return l.op(3, o[1]);
        }
        const ops2 = [_]struct { []const u8, Kind }{
            .{ "++", .inc },        .{ "--", .dec },        .{ "<<", .shl },        .{ ">>", .shr },        .{ "<=", .le },
            .{ ">=", .ge },         .{ "==", .eq },         .{ "!=", .ne },         .{ "&&", .and_and },    .{ "||", .or_or },
            .{ "^^", .xor_xor },    .{ "+=", .add_assign }, .{ "-=", .sub_assign }, .{ "*=", .mul_assign }, .{ "/=", .div_assign },
            .{ "%=", .mod_assign }, .{ "&=", .and_assign }, .{ "^=", .xor_assign }, .{ "|=", .or_assign },  .{ "##", .hash_hash },
        };
        for (ops2) |o| {
            if (std.mem.eql(u8, two, o[0])) return l.op(2, o[1]);
        }
        const k: Kind = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            '.' => .dot,
            ',' => .comma,
            ':' => .colon,
            ';' => .semicolon,
            '?' => .question,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '!' => .bang,
            '~' => .tilde,
            '&' => .amp,
            '|' => .pipe,
            '^' => .caret,
            '<' => .lt,
            '>' => .gt,
            '=' => .assign,
            '#' => .hash,
            else => .bad,
        };
        return l.op(1, k);
    }

    fn op(l: *Lexer, n: usize, k: Kind) Token {
        const t = Token{ .kind = k, .line = l.line, .text = l.src[l.at .. l.at + n] };
        l.at += n;
        return t;
    }

    /// 12, 012 (octal), 0x1F, 3u; 1.5, .5, 1e-3, 2.0f
    fn number(l: *Lexer) Token {
        const s = l.src;
        const start = l.at;
        var is_float = false;
        if (s[l.at] == '0' and l.at + 1 < s.len and (s[l.at + 1] == 'x' or s[l.at + 1] == 'X')) {
            l.at += 2;
            while (l.at < s.len and std.ascii.isHex(s[l.at])) l.at += 1;
        } else {
            while (l.at < s.len and std.ascii.isDigit(s[l.at])) l.at += 1;
            if (l.at < s.len and s[l.at] == '.') {
                is_float = true;
                l.at += 1;
                while (l.at < s.len and std.ascii.isDigit(s[l.at])) l.at += 1;
            }
            if (l.at < s.len and (s[l.at] == 'e' or s[l.at] == 'E')) {
                var j = l.at + 1;
                if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
                if (j < s.len and std.ascii.isDigit(s[j])) {
                    is_float = true;
                    l.at = j;
                    while (l.at < s.len and std.ascii.isDigit(s[l.at])) l.at += 1;
                }
            }
        }
        var kind: Kind = if (is_float) .float_lit else .int_lit;
        if (l.at < s.len) {
            const suf = s[l.at];
            if (is_float and (suf == 'f' or suf == 'F')) {
                l.at += 1;
            } else if (!is_float and (suf == 'u' or suf == 'U')) {
                l.at += 1;
                kind = .uint_lit;
            }
        }
        return .{ .kind = kind, .line = l.line, .text = s[start..l.at] };
    }
};

/// An integer literal's value (decimal, octal, hex; a u suffix dropped);
/// null when it does not fit 32 bits.
pub fn intValue(text: []const u8) ?u32 {
    var t = text;
    if (t.len > 0 and (t[t.len - 1] == 'u' or t[t.len - 1] == 'U')) t = t[0 .. t.len - 1];
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) return std.fmt.parseInt(u32, t[2..], 16) catch null;
    if (t.len > 1 and t[0] == '0') return std.fmt.parseInt(u32, t[1..], 8) catch null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

/// A float literal's value (an f suffix dropped).
pub fn floatValue(text: []const u8) f32 {
    var t = text;
    if (t.len > 0 and (t[t.len - 1] == 'f' or t[t.len - 1] == 'F')) t = t[0 .. t.len - 1];
    return std.fmt.parseFloat(f32, t) catch 0;
}

test "lex: a line's tokens" {
    var l = Lexer{ .src = "x.xy += vec2(1.5e1, .5f) << 3u >>= 0x1F; // ", .line = 7 };
    const want = [_]Kind{ .ident, .dot, .ident, .add_assign, .ident, .lparen, .float_lit, .comma, .float_lit, .rparen, .shl, .uint_lit, .shr_assign, .int_lit, .semicolon, .slash, .slash, .eof };
    for (want) |k| {
        const t = l.next();
        try std.testing.expectEqual(k, t.kind);
        try std.testing.expectEqual(@as(u32, 7), t.line);
    }
    try std.testing.expectEqual(@as(u32, 31), intValue("0x1F").?);
    try std.testing.expectEqual(@as(u32, 8), intValue("010").?);
    try std.testing.expectEqual(@as(u32, 3), intValue("3u").?);
    try std.testing.expect(intValue("99999999999") == null);
    try std.testing.expectEqual(@as(f32, 15), floatValue("1.5e1"));
    try std.testing.expectEqual(Kw.vec2, keyword("vec2", 300));
    try std.testing.expectEqual(Kw.reserved, keyword("attribute", 300));
    try std.testing.expectEqual(Kw.attribute, keyword("attribute", 100));
    try std.testing.expectEqual(Kw.none, keyword("uint", 100));
    try std.testing.expectEqual(Kw.reserved, keyword("goto", 300));
    // (3.00's reserved words are 1.00's names: glamor's Xv `float sample;`)
    try std.testing.expectEqual(Kw.reserved, keyword("sample", 300));
    try std.testing.expectEqual(Kw.none, keyword("sample", 100));
    try std.testing.expectEqual(Kw.none, keyword("patch", 100));
    try std.testing.expectEqual(Kw.reserved, keyword("goto", 100));
}
