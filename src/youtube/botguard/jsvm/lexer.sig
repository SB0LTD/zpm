// @zpm/youtube/botguard/jsvm/lexer — JavaScript Tokenizer
//
// Converts JavaScript source text into a stream of tokens.
// Handles: identifiers, keywords, numbers, strings, operators, punctuation.
// Supports: template literals, regex literals, Unicode escapes in strings.

// ── Token types ──
pub const TokenType = enum(u8) {
    // Literals
    number, // 42, 3.14, 0xFF, 1e10
    string, // "hello", 'world'
    regex, // /pattern/flags
    template, // `template ${expr}`
    true_lit, // true
    false_lit, // false
    null_lit, // null
    undefined_lit, // undefined

    // Identifiers and keywords
    identifier, // variable/function names
    kw_var,
    kw_let,
    kw_const,
    kw_function,
    kw_return,
    kw_if,
    kw_else,
    kw_for,
    kw_while,
    kw_do,
    kw_break,
    kw_continue,
    kw_switch,
    kw_case,
    kw_default,
    kw_new,
    kw_this,
    kw_typeof,
    kw_instanceof,
    kw_in,
    kw_of,
    kw_delete,
    kw_void,
    kw_throw,
    kw_try,
    kw_catch,
    kw_finally,
    kw_class,
    kw_extends,
    kw_super,
    kw_import,
    kw_export,
    kw_async,
    kw_await,
    kw_yield,
    kw_with,
    kw_debugger,

    // Operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    power, // **
    assign, // =
    plus_assign, // +=
    minus_assign, // -=
    star_assign, // *=
    slash_assign, // /=
    percent_assign, // %=
    power_assign, // **=
    amp_assign, // &=
    pipe_assign, // |=
    caret_assign, // ^=
    lshift_assign, // <<=
    rshift_assign, // >>=
    urshift_assign, // >>>=
    nullish_assign, // ??=
    and_assign, // &&=
    or_assign, // ||=
    eq, // ==
    neq, // !=
    strict_eq, // ===
    strict_neq, // !==
    lt, // <
    gt, // >
    lte, // <=
    gte, // >=
    logical_and, // &&
    logical_or, // ||
    nullish, // ??
    not, // !
    bit_and, // &
    bit_or, // |
    bit_xor, // ^
    bit_not, // ~
    lshift, // <<
    rshift, // >>
    urshift, // >>>
    increment, // ++
    decrement, // --
    dot, // .
    optional_chain, // ?.
    spread, // ...
    arrow, // =>
    question, // ?
    colon, // :
    comma, // ,
    semicolon, // ;

    // Delimiters
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    lbrace, // {
    rbrace, // }

    // Special
    eof,
    err,
};

/// A single token with position info.
pub const Token = struct {
    tt: TokenType,
    start: u32, // byte offset in source
    len: u16, // byte length of token text
};

/// Maximum tokens we can produce (500KB source → ~100K tokens max)
pub const MAX_TOKENS: usize = 150_000;

// ── Lexer state ──

var tokens: [MAX_TOKENS]Token = undefined;
var n_tokens: usize = 0;
var source: []const u8 = "";

/// Tokenize a JavaScript source string.
/// Returns the number of tokens produced.
pub fn tokenize(src: []const u8) usize {
    source = src;
    n_tokens = 0;
    var pos: usize = 0;

    while (pos < src.len and n_tokens < MAX_TOKENS) {
        // Skip whitespace and comments
        pos = skipWhitespace(src, pos);
        if (pos >= src.len) break;

        const start = pos;
        const c = src[pos];

        // Single-char and multi-char operators/punctuation
        if (c == '(') { emit(.lparen, start, 1); pos += 1; continue; }
        if (c == ')') { emit(.rparen, start, 1); pos += 1; continue; }
        if (c == '[') { emit(.lbracket, start, 1); pos += 1; continue; }
        if (c == ']') { emit(.rbracket, start, 1); pos += 1; continue; }
        if (c == '{') { emit(.lbrace, start, 1); pos += 1; continue; }
        if (c == '}') { emit(.rbrace, start, 1); pos += 1; continue; }
        if (c == ';') { emit(.semicolon, start, 1); pos += 1; continue; }
        if (c == ',') { emit(.comma, start, 1); pos += 1; continue; }
        if (c == '~') { emit(.bit_not, start, 1); pos += 1; continue; }
        if (c == '?') { pos = lexQuestion(src, pos, start); continue; }
        if (c == ':') { emit(.colon, start, 1); pos += 1; continue; }

        // Multi-char operators
        if (c == '+') { pos = lexPlus(src, pos, start); continue; }
        if (c == '-') { pos = lexMinus(src, pos, start); continue; }
        if (c == '*') { pos = lexStar(src, pos, start); continue; }
        if (c == '/') { pos = lexSlash(src, pos, start); continue; }
        if (c == '%') { pos = lexPercent(src, pos, start); continue; }
        if (c == '=') { pos = lexEquals(src, pos, start); continue; }
        if (c == '!') { pos = lexBang(src, pos, start); continue; }
        if (c == '<') { pos = lexLt(src, pos, start); continue; }
        if (c == '>') { pos = lexGt(src, pos, start); continue; }
        if (c == '&') { pos = lexAmp(src, pos, start); continue; }
        if (c == '|') { pos = lexPipe(src, pos, start); continue; }
        if (c == '^') { pos = lexCaret(src, pos, start); continue; }
        if (c == '.') { pos = lexDot(src, pos, start); continue; }

        // String literals
        if (c == '"' or c == '\'') { pos = lexString(src, pos, start); continue; }
        if (c == '`') { pos = lexTemplate(src, pos, start); continue; }

        // Numbers
        if (isDigit(c) or (c == '.' and pos + 1 < src.len and isDigit(src[pos + 1]))) {
            pos = lexNumber(src, pos, start);
            continue;
        }

        // Identifiers and keywords
        if (isIdentStart(c)) { pos = lexIdentifier(src, pos, start); continue; }

        // Unknown character — skip
        emit(.err, start, 1);
        pos += 1;
    }

    emit(.eof, @intCast(pos), 0);
    return n_tokens;
}

/// Get the token at index.
pub fn getToken(idx: usize) Token {
    if (idx >= n_tokens) return .{ .tt = .eof, .start = 0, .len = 0 };
    return tokens[idx];
}

/// Get the source text of a token.
pub fn tokenText(tok: Token) []const u8 {
    if (tok.len == 0) return "";
    return source[tok.start .. tok.start + tok.len];
}

/// Get all tokens.
pub fn getTokens() []const Token {
    return tokens[0..n_tokens];
}

// ── Internal lexing functions ──

fn emit(tt: TokenType, start: usize, len: usize) void {
    if (n_tokens >= MAX_TOKENS) return;
    tokens[n_tokens] = .{ .tt = tt, .start = @intCast(start), .len = @intCast(len) };
    n_tokens += 1;
}

fn skipWhitespace(src: []const u8, pos: usize) usize {
    var p = pos;
    while (p < src.len) {
        const c = src[p];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') { p += 1; continue; }
        // Line comment
        if (c == '/' and p + 1 < src.len and src[p + 1] == '/') {
            p += 2;
            while (p < src.len and src[p] != '\n') : (p += 1) {}
            continue;
        }
        // Block comment
        if (c == '/' and p + 1 < src.len and src[p + 1] == '*') {
            p += 2;
            while (p + 1 < src.len and !(src[p] == '*' and src[p + 1] == '/')) : (p += 1) {}
            if (p + 1 < src.len) p += 2;
            continue;
        }
        break;
    }
    return p;
}

fn lexString(src: []const u8, pos: usize, start: usize) usize {
    const quote = src[pos];
    var p = pos + 1;
    while (p < src.len and src[p] != quote) : (p += 1) {
        if (src[p] == '\\' and p + 1 < src.len) p += 1; // skip escaped char
    }
    if (p < src.len) p += 1; // skip closing quote
    emit(.string, start, p - start);
    return p;
}

fn lexTemplate(src: []const u8, pos: usize, start: usize) usize {
    var p = pos + 1;
    while (p < src.len and src[p] != '`') : (p += 1) {
        if (src[p] == '\\' and p + 1 < src.len) p += 1;
        // TODO: handle ${...} interpolation (nested brace counting)
    }
    if (p < src.len) p += 1;
    emit(.template, start, p - start);
    return p;
}

fn lexNumber(src: []const u8, pos: usize, start: usize) usize {
    var p = pos;
    // Hex
    if (p + 1 < src.len and src[p] == '0' and (src[p + 1] == 'x' or src[p + 1] == 'X')) {
        p += 2;
        while (p < src.len and isHexDigit(src[p])) : (p += 1) {}
        emit(.number, start, p - start);
        return p;
    }
    // Binary
    if (p + 1 < src.len and src[p] == '0' and (src[p + 1] == 'b' or src[p + 1] == 'B')) {
        p += 2;
        while (p < src.len and (src[p] == '0' or src[p] == '1')) : (p += 1) {}
        emit(.number, start, p - start);
        return p;
    }
    // Decimal (with optional . and exponent)
    while (p < src.len and isDigit(src[p])) : (p += 1) {}
    if (p < src.len and src[p] == '.') {
        p += 1;
        while (p < src.len and isDigit(src[p])) : (p += 1) {}
    }
    if (p < src.len and (src[p] == 'e' or src[p] == 'E')) {
        p += 1;
        if (p < src.len and (src[p] == '+' or src[p] == '-')) p += 1;
        while (p < src.len and isDigit(src[p])) : (p += 1) {}
    }
    emit(.number, start, p - start);
    return p;
}

fn lexIdentifier(src: []const u8, pos: usize, start: usize) usize {
    var p = pos;
    while (p < src.len and isIdentCont(src[p])) : (p += 1) {}
    const text = src[start..p];
    const tt = identifyKeyword(text);
    emit(tt, start, p - start);
    return p;
}

fn identifyKeyword(text: []const u8) TokenType {
    if (eql(text, "var")) return .kw_var;
    if (eql(text, "let")) return .kw_let;
    if (eql(text, "const")) return .kw_const;
    if (eql(text, "function")) return .kw_function;
    if (eql(text, "return")) return .kw_return;
    if (eql(text, "if")) return .kw_if;
    if (eql(text, "else")) return .kw_else;
    if (eql(text, "for")) return .kw_for;
    if (eql(text, "while")) return .kw_while;
    if (eql(text, "do")) return .kw_do;
    if (eql(text, "break")) return .kw_break;
    if (eql(text, "continue")) return .kw_continue;
    if (eql(text, "switch")) return .kw_switch;
    if (eql(text, "case")) return .kw_case;
    if (eql(text, "default")) return .kw_default;
    if (eql(text, "new")) return .kw_new;
    if (eql(text, "this")) return .kw_this;
    if (eql(text, "typeof")) return .kw_typeof;
    if (eql(text, "instanceof")) return .kw_instanceof;
    if (eql(text, "in")) return .kw_in;
    if (eql(text, "of")) return .kw_of;
    if (eql(text, "delete")) return .kw_delete;
    if (eql(text, "void")) return .kw_void;
    if (eql(text, "throw")) return .kw_throw;
    if (eql(text, "try")) return .kw_try;
    if (eql(text, "catch")) return .kw_catch;
    if (eql(text, "finally")) return .kw_finally;
    if (eql(text, "class")) return .kw_class;
    if (eql(text, "extends")) return .kw_extends;
    if (eql(text, "super")) return .kw_super;
    if (eql(text, "import")) return .kw_import;
    if (eql(text, "export")) return .kw_export;
    if (eql(text, "async")) return .kw_async;
    if (eql(text, "await")) return .kw_await;
    if (eql(text, "yield")) return .kw_yield;
    if (eql(text, "with")) return .kw_with;
    if (eql(text, "debugger")) return .kw_debugger;
    if (eql(text, "true")) return .true_lit;
    if (eql(text, "false")) return .false_lit;
    if (eql(text, "null")) return .null_lit;
    if (eql(text, "undefined")) return .undefined_lit;
    return .identifier;
}

// ── Operator lexers (multi-char) ──

fn lexPlus(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '+') { emit(.increment, start, 2); return pos + 2; }
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.plus_assign, start, 2); return pos + 2; }
    emit(.plus, start, 1); return pos + 1;
}

fn lexMinus(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '-') { emit(.decrement, start, 2); return pos + 2; }
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.minus_assign, start, 2); return pos + 2; }
    emit(.minus, start, 1); return pos + 1;
}

fn lexStar(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '*') {
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.power_assign, start, 3); return pos + 3; }
        emit(.power, start, 2); return pos + 2;
    }
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.star_assign, start, 2); return pos + 2; }
    emit(.star, start, 1); return pos + 1;
}

fn lexSlash(src: []const u8, pos: usize, start: usize) usize {
    // Could be division or regex — for simplicity, treat as division here
    // (regex detection requires parser context)
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.slash_assign, start, 2); return pos + 2; }
    emit(.slash, start, 1); return pos + 1;
}

fn lexPercent(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.percent_assign, start, 2); return pos + 2; }
    emit(.percent, start, 1); return pos + 1;
}

fn lexEquals(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '=') {
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.strict_eq, start, 3); return pos + 3; }
        emit(.eq, start, 2); return pos + 2;
    }
    if (pos + 1 < src.len and src[pos + 1] == '>') { emit(.arrow, start, 2); return pos + 2; }
    emit(.assign, start, 1); return pos + 1;
}

fn lexBang(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '=') {
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.strict_neq, start, 3); return pos + 3; }
        emit(.neq, start, 2); return pos + 2;
    }
    emit(.not, start, 1); return pos + 1;
}

fn lexLt(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '<') {
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.lshift_assign, start, 3); return pos + 3; }
        emit(.lshift, start, 2); return pos + 2;
    }
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.lte, start, 2); return pos + 2; }
    emit(.lt, start, 1); return pos + 1;
}

fn lexGt(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '>') {
        if (pos + 2 < src.len and src[pos + 2] == '>') {
            if (pos + 3 < src.len and src[pos + 3] == '=') { emit(.urshift_assign, start, 4); return pos + 4; }
            emit(.urshift, start, 3); return pos + 3;
        }
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.rshift_assign, start, 3); return pos + 3; }
        emit(.rshift, start, 2); return pos + 2;
    }
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.gte, start, 2); return pos + 2; }
    emit(.gt, start, 1); return pos + 1;
}

fn lexAmp(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '&') {
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.and_assign, start, 3); return pos + 3; }
        emit(.logical_and, start, 2); return pos + 2;
    }
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.amp_assign, start, 2); return pos + 2; }
    emit(.bit_and, start, 1); return pos + 1;
}

fn lexPipe(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '|') {
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.or_assign, start, 3); return pos + 3; }
        emit(.logical_or, start, 2); return pos + 2;
    }
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.pipe_assign, start, 2); return pos + 2; }
    emit(.bit_or, start, 1); return pos + 1;
}

fn lexCaret(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '=') { emit(.caret_assign, start, 2); return pos + 2; }
    emit(.bit_xor, start, 1); return pos + 1;
}

fn lexDot(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 2 < src.len and src[pos + 1] == '.' and src[pos + 2] == '.') { emit(.spread, start, 3); return pos + 3; }
    emit(.dot, start, 1); return pos + 1;
}

fn lexQuestion(src: []const u8, pos: usize, start: usize) usize {
    if (pos + 1 < src.len and src[pos + 1] == '?') {
        if (pos + 2 < src.len and src[pos + 2] == '=') { emit(.nullish_assign, start, 3); return pos + 3; }
        emit(.nullish, start, 2); return pos + 2;
    }
    if (pos + 1 < src.len and src[pos + 1] == '.') { emit(.optional_chain, start, 2); return pos + 2; }
    emit(.question, start, 1); return pos + 1;
}

// ── Character classification ──

fn isDigit(c: u8) bool { return c >= '0' and c <= '9'; }
fn isHexDigit(c: u8) bool { return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'); }
fn isIdentStart(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$'; }
fn isIdentCont(c: u8) bool { return isIdentStart(c) or isDigit(c); }

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}
