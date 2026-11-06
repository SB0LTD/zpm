//! Full text search (Layer 0), conformance lane B11 "text": PostgreSQL's
//! default text-search parser (wparser_def.c), the `simple` configuration
//! and dictionary, tsvector / tsquery text I/O (tsvector.c,
//! tsvector_parser.c, tsquery.c), to_tsvector, to_tsquery,
//! plainto_tsquery, phraseto_tsquery and the @@ match (tsvector_op.c
//! TS_execute and TS_phrase_execute).
//!
//! Values are kept as their canonical output text (tsvector: sorted
//! unique lexemes with sorted positions; tsquery: the infix form), so a
//! stored value re-parses exactly; the matcher parses both sides into
//! bounded caller-stack tables. Nothing allocates.
//!
//! The parser's state tables are a mechanical translation of
//! wparser_def.c (PostgreSQL 18.3). Character classes follow this
//! database's C ctype under UTF-8 (TParser's pgwstr path): non-ASCII
//! characters are letters and alphanumerics and nothing else. Only the
//! `simple` configuration exists here: every token type except blank,
//! tag, protocol and entity maps to the simple dictionary, which folds
//! ASCII letters to lower case. The other built-in configurations
//! (english, ... with Snowball stemmers) are 0A000; unknown names 42704.
const std = @import("std");
const types = @import("types.sig");
const Error = types.Error;

// ---- default parser ----------------------------------------------------------

/// Token types (wparser_def.c): 12 blank, 13 tag, 14 protocol and 23
/// entity are not indexed by `simple`.
pub fn simpleIndexes(kind: u8) bool {
    return kind >= 1 and kind <= 22 and kind != 12 and kind != 13 and kind != 14;
}

const Test = enum(u8) { always, eof, eq, alnum, alpha, asclet, digit, notalnum, space, special, stophost, ignore, host, url_path, urlchar, xdigit };
const Special = enum(u8) { none, tags, furl, hyphen, ver_version };
/// One action (TParserStateActionItem): test, its character, A_* flags,
/// the next state, the token type for A_BINGO and the special handler.
const Item = struct { t: Test, c: u8, f: u8, to: State, k: u8, s: Special };
const a_bingo: u8 = 1;
const a_pop: u8 = 2;
const a_push: u8 = 4;
const a_rerun: u8 = 8;
const a_clear: u8 = 16;
const a_merge: u8 = 32;
const a_clrall: u8 = 64;

/// Pushed parser positions one token can stack (54001 beyond).
const max_stack = 64;
/// Nested host / URL-path sub-parsers (p_ishost, p_isURLPath).
const max_sub_parsers = 4;

fn utf8Length(bytes: []const u8, at: usize) usize {
    const lead = bytes[at];
    const width: usize = if (lead < 0x80) 1 else if (lead >= 0xf0) 4 else if (lead >= 0xe0) 3 else if (lead >= 0xc0) 2 else 1;
    return @min(width, bytes.len - at);
}

const Position = struct {
    posbyte: usize = 0,
    poschar: usize = 0,
    charlen: usize = 0,
    lenbytetoken: usize = 0,
    lenchartoken: usize = 0,
    state: State = .base,
    /// After a pop: resume at the action after this one.
    pushed: ?usize = null,
};

/// TParser over `str`; next() returns the next token's type (0 at the end).
pub const Parser = struct {
    str: []const u8,
    stack: [max_stack]Position = undefined,
    top: usize = 0,
    ignore: bool = false,
    wanthost: bool = false,
    c: u8 = 0,
    token: usize = 0,
    lenbytetoken: usize = 0,
    lenchartoken: usize = 0,
    kind: u8 = 0,

    pub fn init(str: []const u8) Parser {
        var self: Parser = .{ .str = str };
        self.stack[0] = .{};
        return self;
    }

    fn state(self: *Parser) *Position {
        return &self.stack[self.top];
    }

    fn byteAt(self: *Parser) u8 {
        return self.str[self.state().posbyte];
    }

    fn ascii(self: *Parser) bool {
        return self.state().charlen == 1 and self.byteAt() < 0x80;
    }

    fn isAlpha(self: *Parser) bool {
        if (self.state().charlen != 1) return self.state().charlen > 1;
        const b = self.byteAt();
        if (b >= 0x80) return true;
        return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
    }

    fn isDigit(self: *Parser) bool {
        if (self.state().charlen != 1) return false;
        const b = self.byteAt();
        return b >= '0' and b <= '9';
    }

    fn isSpace(self: *Parser) bool {
        if (self.state().charlen != 1) return false;
        const b = self.byteAt();
        return b == ' ' or (b >= 9 and b <= 13);
    }

    fn isXdigit(self: *Parser) bool {
        if (self.state().charlen != 1) return false;
        const b = self.byteAt() | 0x20;
        return self.isDigit() or (b >= 'a' and b <= 'f');
    }

    fn isEof(self: *Parser) bool {
        return self.state().posbyte == self.str.len or self.state().charlen == 0;
    }

    fn isUrlChar(self: *Parser) bool {
        if (self.state().charlen != 1) return false;
        const b = self.byteAt();
        if (b <= 0x20 or b >= 0x7f) return false;
        return switch (b) {
            '"', '<', '>', '\\', '^', '`', '{', '|', '}' => false,
            else => true,
        };
    }

    fn holds(self: *Parser, comptime level: usize, item: Item) Error!bool {
        self.c = item.c;
        return switch (item.t) {
            .always => true,
            .eof => self.isEof(),
            .eq => self.state().charlen == 1 and self.byteAt() == item.c,
            .alnum => self.isAlpha() or self.isDigit(),
            .alpha => self.isAlpha(),
            .asclet => self.ascii() and self.isAlpha(),
            .digit => self.isDigit(),
            .notalnum => !(self.isAlpha() or self.isDigit()),
            .space => self.isSpace(),
            // pg_dsplen() == 0 or a spacing combining mark: never reached
            // for a character that is not already a letter in C ctype.
            .special => false,
            .stophost => blk: {
                if (!self.wanthost) break :blk false;
                self.wanthost = false;
                break :blk true;
            },
            .ignore => self.ignore,
            .host, .url_path => try self.subParser(level, item.t == .host),
            .urlchar => self.isUrlChar(),
            .xdigit => self.isXdigit(),
        };
    }

    /// p_ishost / p_isURLPath: a copy of the parser from here must return
    /// a HOST (wanting a host) or a URLPATH (from TPS_InURLPathFirst).
    fn subParser(self: *Parser, comptime level: usize, host: bool) Error!bool {
        if (comptime level + 1 >= max_sub_parsers) {
            return error.StatementTooComplex;
        } else {
            var copy = Parser.init(self.str);
            copy.stack[0].posbyte = self.state().posbyte;
            copy.stack[0].poschar = self.state().poschar;
            if (host) {
                copy.wanthost = true;
            } else {
                copy.stack[1] = copy.stack[0];
                copy.stack[1].state = .in_urlpath_first;
                copy.top = 1;
            }
            if (!try copy.get(level + 1) or copy.kind != (if (host) @as(u8, 6) else 18)) return false;
            const st = self.state();
            st.posbyte += copy.lenbytetoken;
            st.poschar += copy.lenchartoken;
            st.lenbytetoken += copy.lenbytetoken;
            st.lenchartoken += copy.lenchartoken;
            st.charlen = copy.state().charlen;
            return true;
        }
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        const token = self.str[self.token..];
        if (token.len < prefix.len) return false;
        for (prefix, token[0..prefix.len]) |a, b| {
            const lower = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (a != lower) return false;
        }
        return true;
    }

    fn special(self: *Parser, which: Special) void {
        const st = self.state();
        switch (which) {
            .none => {},
            .tags => switch (st.lenchartoken) {
                8 => if (self.startsWith("</script")) {
                    self.ignore = false;
                },
                7 => if (self.startsWith("</style")) {
                    self.ignore = false;
                } else if (self.startsWith("<script")) {
                    self.ignore = true;
                },
                6 => if (self.startsWith("<style")) {
                    self.ignore = true;
                },
                else => {},
            },
            .furl => {
                self.wanthost = true;
                st.posbyte -|= st.lenbytetoken;
                st.poschar -|= st.lenchartoken;
            },
            .hyphen => {
                st.posbyte -|= st.lenbytetoken;
                st.poschar -|= st.lenchartoken;
            },
            .ver_version => {
                st.posbyte -|= st.lenbytetoken;
                st.poschar -|= st.lenchartoken;
                st.lenbytetoken = 0;
                st.lenchartoken = 0;
            },
        }
    }

    /// TParserGet: whether a token was found (its type in `kind`).
    pub fn get(self: *Parser, comptime level: usize) Error!bool {
        if (self.state().posbyte >= self.str.len) return false;
        self.token = self.state().posbyte;
        self.state().pushed = null;
        var item: Item = undefined;
        while (self.state().posbyte <= self.str.len) {
            const st = self.state();
            st.charlen = if (st.posbyte == self.str.len) 0 else utf8Length(self.str, st.posbyte);
            const table = actions(st.state);
            var index: usize = 0;
            if (st.pushed) |at| {
                index = at + 1;
                st.pushed = null;
            }
            while (true) : (index += 1) {
                item = table[index];
                if (item.t == .always or try self.holds(level, item)) break;
            }
            self.special(item.s);
            if (item.f & a_bingo != 0) {
                self.lenbytetoken = self.state().lenbytetoken;
                self.lenchartoken = self.state().lenchartoken;
                self.state().lenbytetoken = 0;
                self.state().lenchartoken = 0;
                self.kind = item.k;
            }
            if (item.f & a_pop != 0) {
                if (self.top == 0) return error.StatementTooComplex;
                self.top -= 1;
            } else if (item.f & a_push != 0) {
                if (self.top + 1 == max_stack) return error.StatementTooComplex;
                self.state().pushed = index;
                self.stack[self.top + 1] = self.stack[self.top];
                self.top += 1;
                self.state().pushed = null;
            } else if (item.f & a_clear != 0) {
                if (self.top == 0) return error.StatementTooComplex;
                self.stack[self.top - 1] = self.stack[self.top];
                self.top -= 1;
                // The cleared entry was the one below; keep the current one.
            } else if (item.f & a_clrall != 0) {
                self.stack[0] = self.stack[self.top];
                self.top = 0;
            } else if (item.f & a_merge != 0) {
                if (self.top == 0) return error.StatementTooComplex;
                const merged = self.stack[self.top];
                self.top -= 1;
                const below = self.state();
                below.posbyte = merged.posbyte;
                below.poschar = merged.poschar;
                below.charlen = merged.charlen;
                below.lenbytetoken = merged.lenbytetoken;
                below.lenchartoken = merged.lenchartoken;
            }
            if (item.to != .null) self.state().state = item.to;
            if (item.f & a_bingo != 0 or (self.state().posbyte >= self.str.len and item.f & a_rerun == 0)) break;
            if (item.f & (a_rerun | a_pop) != 0) continue;
            const now = self.state();
            if (now.charlen != 0) {
                now.posbyte += now.charlen;
                now.lenbytetoken += now.charlen;
                now.poschar += 1;
                now.lenchartoken += 1;
            }
        }
        return item.f & a_bingo != 0;
    }

    /// The next token: its type (0 at the end) and bytes.
    pub fn next(self: *Parser) Error!?struct { kind: u8, bytes: []const u8 } {
        if (!try self.get(0)) return null;
        return .{ .kind = self.kind, .bytes = self.str[self.token..][0..self.lenbytetoken] };
    }
};

/// Parser states (TParserState).
const State = enum(u8) { base, in_num_word, in_ascii_word, in_word, in_unsigned_int, in_signed_int_first, in_signed_int, in_space, in_udecimal_first, in_udecimal, in_decimal_first, in_decimal, in_ver_version, in_sver_version, in_version_first, in_version, in_mantissa_first, in_mantissa_sign, in_mantissa, in_xmlentity_first, in_xmlentity, in_xmlentity_num_first, in_xmlentity_num, in_xmlentity_hex_num_first, in_xmlentity_hex_num, in_xmlentity_end, in_tag_first, in_xmlbegin, in_tag_close_first, in_tag_name, in_tag_begin_end, in_tag, in_tag_escape_k, in_tag_escape_kk, in_tag_back_sleshed, in_tag_end, in_comment_first, in_comment_last, in_comment, in_close_comment_first, in_close_comment_last, in_comment_end, in_host_first_domain, in_host_domain_second, in_host_domain, in_port_first, in_port, in_host_first_an, in_host, in_email, in_file_first, in_file_twiddle, in_path_first, in_path_first_first, in_path_second, in_file, in_file_next, in_urlpath_first, in_urlpath_start, in_urlpath, in_furl, in_protocol_first, in_protocol_second, in_protocol_end, in_hyphen_ascii_word_first, in_hyphen_ascii_word, in_hyphen_word_first, in_hyphen_word, in_hyphen_num_word_first, in_hyphen_num_word, in_hyphen_digit_lookahead, in_parse_hyphen, in_parse_hyphen_hyphen, in_hyphen_word_part, in_hyphen_ascii_word_part, in_hyphen_num_word_part, in_hyphen_unsigned_int, null };

const t_base = [_]Item{
    .{ .t = .eof, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 60, .f = 4, .to = .in_tag_first, .k = 0, .s = .none },
    .{ .t = .ignore, .c = 0, .f = 0, .to = .in_space, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_ascii_word, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_word, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_unsigned_int, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_signed_int_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 43, .f = 4, .to = .in_signed_int_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 38, .f = 4, .to = .in_xmlentity_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 126, .f = 4, .to = .in_file_twiddle, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_path_first_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 0, .to = .in_space, .k = 0, .s = .none },
};
const t_in_num_word = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 3, .s = .none },
    .{ .t = .alnum, .c = 0, .f = 0, .to = .in_num_word, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_num_word, .k = 0, .s = .none },
    .{ .t = .eq, .c = 64, .f = 4, .to = .in_email, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_file_next, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_hyphen_num_word_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 3, .s = .none },
};
const t_in_ascii_word = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 1, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_host_first_domain, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_file_next, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_hyphen_ascii_word_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 64, .f = 4, .to = .in_email, .k = 0, .s = .none },
    .{ .t = .eq, .c = 58, .f = 4, .to = .in_protocol_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 4, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_num_word, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_word, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_word, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 1, .s = .none },
};
const t_in_word = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 2, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_num_word, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_hyphen_word_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 2, .s = .none },
};
const t_in_unsigned_int = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 22, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_host_first_domain, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_udecimal_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 101, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 69, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 64, .f = 4, .to = .in_email, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 4, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_num_word, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_num_word, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 22, .s = .none },
};
const t_in_signed_int_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 16, .to = .in_signed_int, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_signed_int = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 21, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_decimal_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 101, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 69, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 21, .s = .none },
};
const t_in_space = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 12, .s = .none },
    .{ .t = .eq, .c = 60, .f = 1, .to = .base, .k = 12, .s = .none },
    .{ .t = .ignore, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 1, .to = .base, .k = 12, .s = .none },
    .{ .t = .eq, .c = 43, .f = 1, .to = .base, .k = 12, .s = .none },
    .{ .t = .eq, .c = 38, .f = 1, .to = .base, .k = 12, .s = .none },
    .{ .t = .eq, .c = 47, .f = 1, .to = .base, .k = 12, .s = .none },
    .{ .t = .notalnum, .c = 0, .f = 0, .to = .in_space, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 12, .s = .none },
};
const t_in_udecimal_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 16, .to = .in_udecimal, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_udecimal = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 20, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_udecimal, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_version_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 101, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 69, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 20, .s = .none },
};
const t_in_decimal_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 16, .to = .in_decimal, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_decimal = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 20, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_decimal, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_ver_version, .k = 0, .s = .none },
    .{ .t = .eq, .c = 101, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 69, .f = 4, .to = .in_mantissa_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 20, .s = .none },
};
const t_in_ver_version = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 8, .to = .in_sver_version, .k = 0, .s = .ver_version },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_sver_version = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 65, .to = .in_unsigned_int, .k = 12, .s = .none },
    .{ .t = .always, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
};
const t_in_version_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 16, .to = .in_version, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_version = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 8, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_version, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_version_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 8, .s = .none },
};
const t_in_mantissa_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 16, .to = .in_mantissa, .k = 0, .s = .none },
    .{ .t = .eq, .c = 43, .f = 0, .to = .in_mantissa_sign, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .in_mantissa_sign, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_mantissa_sign = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 16, .to = .in_mantissa, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_mantissa = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 7, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_mantissa, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 7, .s = .none },
};
const t_in_xmlentity_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 35, .f = 0, .to = .in_xmlentity_num_first, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .eq, .c = 58, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_xmlentity = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .alnum, .c = 0, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .eq, .c = 58, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .in_xmlentity, .k = 0, .s = .none },
    .{ .t = .eq, .c = 59, .f = 0, .to = .in_xmlentity_end, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_xmlentity_num_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 120, .f = 0, .to = .in_xmlentity_hex_num_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 88, .f = 0, .to = .in_xmlentity_hex_num_first, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_xmlentity_num, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_xmlentity_num = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_xmlentity_num, .k = 0, .s = .none },
    .{ .t = .eq, .c = 59, .f = 0, .to = .in_xmlentity_end, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_xmlentity_hex_num_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .xdigit, .c = 0, .f = 0, .to = .in_xmlentity_hex_num, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_xmlentity_hex_num = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .xdigit, .c = 0, .f = 0, .to = .in_xmlentity_hex_num, .k = 0, .s = .none },
    .{ .t = .eq, .c = 59, .f = 0, .to = .in_xmlentity_end, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_xmlentity_end = [_]Item{
    .{ .t = .always, .c = 0, .f = 17, .to = .base, .k = 23, .s = .none },
};
const t_in_tag_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_tag_close_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 33, .f = 4, .to = .in_comment_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 63, .f = 4, .to = .in_xmlbegin, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 4, .to = .in_tag_name, .k = 0, .s = .none },
    .{ .t = .eq, .c = 58, .f = 4, .to = .in_tag_name, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 4, .to = .in_tag_name, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_xmlbegin = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 120, .f = 0, .to = .in_tag, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_tag_close_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_tag_name, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_tag_name = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 0, .to = .in_tag_begin_end, .k = 0, .s = .none },
    .{ .t = .eq, .c = 62, .f = 0, .to = .in_tag_end, .k = 0, .s = .tags },
    .{ .t = .space, .c = 0, .f = 0, .to = .in_tag, .k = 0, .s = .tags },
    .{ .t = .alnum, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 58, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_tag_begin_end = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 62, .f = 0, .to = .in_tag_end, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_tag = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 62, .f = 0, .to = .in_tag_end, .k = 0, .s = .tags },
    .{ .t = .eq, .c = 39, .f = 0, .to = .in_tag_escape_k, .k = 0, .s = .none },
    .{ .t = .eq, .c = 34, .f = 0, .to = .in_tag_escape_kk, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 61, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 35, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 58, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 38, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 63, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 37, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 126, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .space, .c = 0, .f = 0, .to = .null, .k = 0, .s = .tags },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_tag_escape_k = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 92, .f = 4, .to = .in_tag_back_sleshed, .k = 0, .s = .none },
    .{ .t = .eq, .c = 39, .f = 0, .to = .in_tag, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 0, .to = .in_tag_escape_k, .k = 0, .s = .none },
};
const t_in_tag_escape_kk = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 92, .f = 4, .to = .in_tag_back_sleshed, .k = 0, .s = .none },
    .{ .t = .eq, .c = 34, .f = 0, .to = .in_tag, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 0, .to = .in_tag_escape_kk, .k = 0, .s = .none },
};
const t_in_tag_back_sleshed = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 32, .to = .null, .k = 0, .s = .none },
};
const t_in_tag_end = [_]Item{
    .{ .t = .always, .c = 0, .f = 65, .to = .base, .k = 13, .s = .none },
};
const t_in_comment_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .in_comment_last, .k = 0, .s = .none },
    .{ .t = .eq, .c = 68, .f = 0, .to = .in_tag, .k = 0, .s = .none },
    .{ .t = .eq, .c = 100, .f = 0, .to = .in_tag, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_comment_last = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .in_comment, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_comment = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .in_close_comment_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
};
const t_in_close_comment_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .in_close_comment_last, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 0, .to = .in_comment, .k = 0, .s = .none },
};
const t_in_close_comment_last = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 62, .f = 0, .to = .in_comment_end, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 0, .to = .in_comment, .k = 0, .s = .none },
};
const t_in_comment_end = [_]Item{
    .{ .t = .always, .c = 0, .f = 65, .to = .base, .k = 13, .s = .none },
};
const t_in_host_first_domain = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_host_domain_second, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_host_domain_second = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_host_domain, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 4, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_host_first_domain, .k = 0, .s = .none },
    .{ .t = .eq, .c = 64, .f = 4, .to = .in_email, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_host_domain = [_]Item{
    .{ .t = .eof, .c = 0, .f = 65, .to = .base, .k = 6, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_host_domain, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 4, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .eq, .c = 58, .f = 4, .to = .in_port_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_host_first_domain, .k = 0, .s = .none },
    .{ .t = .eq, .c = 64, .f = 4, .to = .in_email, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .stophost, .c = 0, .f = 65, .to = .in_urlpath_start, .k = 6, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_furl, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 65, .to = .base, .k = 6, .s = .none },
};
const t_in_port_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_port, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_port = [_]Item{
    .{ .t = .eof, .c = 0, .f = 65, .to = .base, .k = 6, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_port, .k = 0, .s = .none },
    .{ .t = .stophost, .c = 0, .f = 65, .to = .in_urlpath_start, .k = 6, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_furl, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 65, .to = .base, .k = 6, .s = .none },
};
const t_in_host_first_an = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_host = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_host, .k = 0, .s = .none },
    .{ .t = .eq, .c = 64, .f = 4, .to = .in_email, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_host_first_domain, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 4, .to = .in_host_first_an, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_email = [_]Item{
    .{ .t = .stophost, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .host, .c = 0, .f = 65, .to = .base, .k = 4, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_file_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 0, .to = .in_path_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 126, .f = 4, .to = .in_file_twiddle, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_file_twiddle = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 0, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_path_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 0, .to = .in_path_second, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 0, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_path_first_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 0, .to = .in_path_second, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 0, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_path_second = [_]Item{
    .{ .t = .eof, .c = 0, .f = 17, .to = .base, .k = 19, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 17, .to = .base, .k = 19, .s = .none },
    .{ .t = .space, .c = 0, .f = 17, .to = .base, .k = 19, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_file = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 19, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 46, .f = 4, .to = .in_file_next, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 0, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 4, .to = .in_file_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 19, .s = .none },
};
const t_in_file_next = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 16, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 16, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .eq, .c = 95, .f = 16, .to = .in_file, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_urlpath_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .urlchar, .c = 0, .f = 0, .to = .in_urlpath, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_urlpath_start = [_]Item{
    .{ .t = .always, .c = 0, .f = 0, .to = .in_urlpath, .k = 0, .s = .none },
};
const t_in_urlpath = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 18, .s = .none },
    .{ .t = .urlchar, .c = 0, .f = 0, .to = .in_urlpath, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .base, .k = 18, .s = .none },
};
const t_in_furl = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .url_path, .c = 0, .f = 65, .to = .base, .k = 5, .s = .furl },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_protocol_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 0, .to = .in_protocol_second, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_protocol_second = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .eq, .c = 47, .f = 0, .to = .in_protocol_end, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_protocol_end = [_]Item{
    .{ .t = .always, .c = 0, .f = 65, .to = .base, .k = 14, .s = .none },
};
const t_in_hyphen_ascii_word_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_hyphen_ascii_word, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_word, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_digit_lookahead, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_hyphen_ascii_word = [_]Item{
    .{ .t = .eof, .c = 0, .f = 65, .to = .in_parse_hyphen, .k = 16, .s = .hyphen },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_hyphen_ascii_word, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_word, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_hyphen_word, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_num_word, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_hyphen_ascii_word_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 65, .to = .in_parse_hyphen, .k = 16, .s = .hyphen },
};
const t_in_hyphen_word_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_word, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_digit_lookahead, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_hyphen_word = [_]Item{
    .{ .t = .eof, .c = 0, .f = 65, .to = .in_parse_hyphen, .k = 17, .s = .hyphen },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_word, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_hyphen_word, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_num_word, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_hyphen_word_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 65, .to = .in_parse_hyphen, .k = 17, .s = .hyphen },
};
const t_in_hyphen_num_word_first = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_num_word, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_digit_lookahead, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_hyphen_num_word = [_]Item{
    .{ .t = .eof, .c = 0, .f = 65, .to = .in_parse_hyphen, .k = 15, .s = .hyphen },
    .{ .t = .alnum, .c = 0, .f = 0, .to = .in_hyphen_num_word, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_hyphen_num_word, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_hyphen_num_word_first, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 65, .to = .in_parse_hyphen, .k = 15, .s = .hyphen },
};
const t_in_hyphen_digit_lookahead = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_digit_lookahead, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_num_word, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_hyphen_num_word, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_parse_hyphen = [_]Item{
    .{ .t = .eof, .c = 0, .f = 8, .to = .base, .k = 0, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_hyphen_ascii_word_part, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_word_part, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 4, .to = .in_hyphen_unsigned_int, .k = 0, .s = .none },
    .{ .t = .eq, .c = 45, .f = 4, .to = .in_parse_hyphen_hyphen, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 8, .to = .base, .k = 0, .s = .none },
};
const t_in_parse_hyphen_hyphen = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .alnum, .c = 0, .f = 17, .to = .in_parse_hyphen, .k = 12, .s = .none },
    .{ .t = .special, .c = 0, .f = 17, .to = .in_parse_hyphen, .k = 12, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};
const t_in_hyphen_word_part = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 10, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_word_part, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_hyphen_word_part, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_num_word_part, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .in_parse_hyphen, .k = 10, .s = .none },
};
const t_in_hyphen_ascii_word_part = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 11, .s = .none },
    .{ .t = .asclet, .c = 0, .f = 0, .to = .in_hyphen_ascii_word_part, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 0, .to = .in_hyphen_word_part, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_hyphen_word_part, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .in_hyphen_num_word_part, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .in_parse_hyphen, .k = 11, .s = .none },
};
const t_in_hyphen_num_word_part = [_]Item{
    .{ .t = .eof, .c = 0, .f = 1, .to = .base, .k = 9, .s = .none },
    .{ .t = .alnum, .c = 0, .f = 0, .to = .in_hyphen_num_word_part, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 0, .to = .in_hyphen_num_word_part, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 1, .to = .in_parse_hyphen, .k = 9, .s = .none },
};
const t_in_hyphen_unsigned_int = [_]Item{
    .{ .t = .eof, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
    .{ .t = .digit, .c = 0, .f = 0, .to = .null, .k = 0, .s = .none },
    .{ .t = .alpha, .c = 0, .f = 16, .to = .in_hyphen_num_word_part, .k = 0, .s = .none },
    .{ .t = .special, .c = 0, .f = 16, .to = .in_hyphen_num_word_part, .k = 0, .s = .none },
    .{ .t = .always, .c = 0, .f = 2, .to = .null, .k = 0, .s = .none },
};

fn actions(state: State) []const Item {
    return switch (state) {
        .base => &t_base,
        .in_num_word => &t_in_num_word,
        .in_ascii_word => &t_in_ascii_word,
        .in_word => &t_in_word,
        .in_unsigned_int => &t_in_unsigned_int,
        .in_signed_int_first => &t_in_signed_int_first,
        .in_signed_int => &t_in_signed_int,
        .in_space => &t_in_space,
        .in_udecimal_first => &t_in_udecimal_first,
        .in_udecimal => &t_in_udecimal,
        .in_decimal_first => &t_in_decimal_first,
        .in_decimal => &t_in_decimal,
        .in_ver_version => &t_in_ver_version,
        .in_sver_version => &t_in_sver_version,
        .in_version_first => &t_in_version_first,
        .in_version => &t_in_version,
        .in_mantissa_first => &t_in_mantissa_first,
        .in_mantissa_sign => &t_in_mantissa_sign,
        .in_mantissa => &t_in_mantissa,
        .in_xmlentity_first => &t_in_xmlentity_first,
        .in_xmlentity => &t_in_xmlentity,
        .in_xmlentity_num_first => &t_in_xmlentity_num_first,
        .in_xmlentity_num => &t_in_xmlentity_num,
        .in_xmlentity_hex_num_first => &t_in_xmlentity_hex_num_first,
        .in_xmlentity_hex_num => &t_in_xmlentity_hex_num,
        .in_xmlentity_end => &t_in_xmlentity_end,
        .in_tag_first => &t_in_tag_first,
        .in_xmlbegin => &t_in_xmlbegin,
        .in_tag_close_first => &t_in_tag_close_first,
        .in_tag_name => &t_in_tag_name,
        .in_tag_begin_end => &t_in_tag_begin_end,
        .in_tag => &t_in_tag,
        .in_tag_escape_k => &t_in_tag_escape_k,
        .in_tag_escape_kk => &t_in_tag_escape_kk,
        .in_tag_back_sleshed => &t_in_tag_back_sleshed,
        .in_tag_end => &t_in_tag_end,
        .in_comment_first => &t_in_comment_first,
        .in_comment_last => &t_in_comment_last,
        .in_comment => &t_in_comment,
        .in_close_comment_first => &t_in_close_comment_first,
        .in_close_comment_last => &t_in_close_comment_last,
        .in_comment_end => &t_in_comment_end,
        .in_host_first_domain => &t_in_host_first_domain,
        .in_host_domain_second => &t_in_host_domain_second,
        .in_host_domain => &t_in_host_domain,
        .in_port_first => &t_in_port_first,
        .in_port => &t_in_port,
        .in_host_first_an => &t_in_host_first_an,
        .in_host => &t_in_host,
        .in_email => &t_in_email,
        .in_file_first => &t_in_file_first,
        .in_file_twiddle => &t_in_file_twiddle,
        .in_path_first => &t_in_path_first,
        .in_path_first_first => &t_in_path_first_first,
        .in_path_second => &t_in_path_second,
        .in_file => &t_in_file,
        .in_file_next => &t_in_file_next,
        .in_urlpath_first => &t_in_urlpath_first,
        .in_urlpath_start => &t_in_urlpath_start,
        .in_urlpath => &t_in_urlpath,
        .in_furl => &t_in_furl,
        .in_protocol_first => &t_in_protocol_first,
        .in_protocol_second => &t_in_protocol_second,
        .in_protocol_end => &t_in_protocol_end,
        .in_hyphen_ascii_word_first => &t_in_hyphen_ascii_word_first,
        .in_hyphen_ascii_word => &t_in_hyphen_ascii_word,
        .in_hyphen_word_first => &t_in_hyphen_word_first,
        .in_hyphen_word => &t_in_hyphen_word,
        .in_hyphen_num_word_first => &t_in_hyphen_num_word_first,
        .in_hyphen_num_word => &t_in_hyphen_num_word,
        .in_hyphen_digit_lookahead => &t_in_hyphen_digit_lookahead,
        .in_parse_hyphen => &t_in_parse_hyphen,
        .in_parse_hyphen_hyphen => &t_in_parse_hyphen_hyphen,
        .in_hyphen_word_part => &t_in_hyphen_word_part,
        .in_hyphen_ascii_word_part => &t_in_hyphen_ascii_word_part,
        .in_hyphen_num_word_part => &t_in_hyphen_num_word_part,
        .in_hyphen_unsigned_int => &t_in_hyphen_unsigned_int,
        .null => &t_base,
    };
}

// ---- configurations ----------------------------------------------------------

pub const Config = enum { simple };

/// regconfigin: an identifier list (surrounding spaces allowed, unquoted
/// parts folded to lower case) naming `simple`, optionally qualified by
/// pg_catalog. Snowball configurations are 0A000; anything else 42704.
pub fn configByNameImpl(input: []const u8) Error!Config {
    var parts: [2][64]u8 = undefined;
    var lengths: [2]usize = .{ 0, 0 };
    var count: usize = 0;
    var at: usize = 0;
    while (at < input.len and input[at] == ' ') at += 1;
    while (true) {
        if (count == 2) return error.UndefinedObject;
        var len: usize = 0;
        if (at < input.len and input[at] == '"') {
            at += 1;
            while (true) : (at += 1) {
                if (at >= input.len) return error.UndefinedObject;
                if (input[at] == '"') {
                    if (at + 1 < input.len and input[at + 1] == '"') {
                        at += 1;
                    } else break;
                }
                if (len == 64) return error.UndefinedObject;
                parts[count][len] = input[at];
                len += 1;
            }
            at += 1;
        } else {
            while (at < input.len and input[at] != '.' and input[at] != ' ') : (at += 1) {
                if (len == 64) return error.UndefinedObject;
                const byte = input[at];
                parts[count][len] = if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
                len += 1;
            }
        }
        if (len == 0) return error.UndefinedObject;
        lengths[count] = len;
        count += 1;
        while (at < input.len and input[at] == ' ') at += 1;
        if (at < input.len and input[at] == '.') {
            at += 1;
            while (at < input.len and input[at] == ' ') at += 1;
            continue;
        }
        if (at != input.len) return error.UndefinedObject;
        break;
    }
    if (count == 2 and !types.same(parts[0][0..lengths[0]], "pg_catalog")) return error.UndefinedObject;
    const name = parts[count - 1][0..lengths[count - 1]];
    if (types.same(name, "simple")) return .simple;
    const snowball = [_][]const u8{ "arabic", "armenian", "basque", "catalan", "danish", "dutch", "english", "finnish", "french", "german", "greek", "hindi", "hungarian", "indonesian", "irish", "italian", "lithuanian", "nepali", "norwegian", "portuguese", "romanian", "russian", "serbian", "spanish", "swedish", "tamil", "turkish", "yiddish" };
    for (snowball) |candidate| if (types.same(candidate, name)) return error.UnsupportedStatement;
    return error.UndefinedObject;
}

/// MAXSTRLEN: longer words are skipped by to_tsvector.
const max_word = 2047;
/// MAXENTRYPOS - 1 and MAXNUMPOS.
const max_position = 16383;
const max_positions_per_lexeme = 256;

pub fn TextSearch(comptime text_bytes: usize, comptime depth_limit: usize) type {
    // Every query node takes at least three bytes of output text ('x',
    // ` & `), every token two of input and every position two of output:
    // larger values cannot fit a cell anyway (54000).
    const max_entries = text_bytes / 2 + 2;
    const max_positions = text_bytes / 2 + 2;
    const max_nodes = text_bytes / 3 + 4;
    return struct {
        /// Output text being built.
        pub const Out = struct {
            bytes: [text_bytes]u8 = undefined,
            len: usize = 0,

            fn put(self: *Out, data: []const u8) Error!void {
                if (data.len > self.bytes.len - self.len) return error.TextCapacity;
                @memcpy(self.bytes[self.len..][0..data.len], data);
                self.len += data.len;
            }

            fn number(self: *Out, value: usize) Error!void {
                var digits: [20]u8 = undefined;
                var at: usize = digits.len;
                var rest = value;
                while (true) {
                    at -= 1;
                    digits[at] = @intCast('0' + rest % 10);
                    rest /= 10;
                    if (rest == 0) break;
                }
                try self.put(digits[at..]);
            }

            pub fn slice(self: *const Out) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        /// Lexeme text with optional positions (weight << 14 | position).
        pub const Entry = struct { start: u32 = 0, len: u32 = 0, pos_start: u32 = 0, pos_count: u32 = 0 };

        pub const Vector = struct {
            bytes: [text_bytes]u8 = undefined,
            bytes_len: usize = 0,
            entries: [max_entries]Entry = undefined,
            count: usize = 0,
            positions: [max_positions]u16 = undefined,
            pos_len: usize = 0,

            fn lexeme(self: *const Vector, entry: Entry) []const u8 {
                return self.bytes[entry.start..][0..entry.len];
            }

            fn add(self: *Vector, word: []const u8) Error!*Entry {
                if (self.count == max_entries) return error.TextCapacity;
                if (word.len > text_bytes - self.bytes_len) return error.TextCapacity;
                @memcpy(self.bytes[self.bytes_len..][0..word.len], word);
                self.entries[self.count] = .{ .start = @intCast(self.bytes_len), .len = @intCast(word.len), .pos_start = @intCast(self.pos_len) };
                self.bytes_len += word.len;
                self.count += 1;
                return &self.entries[self.count - 1];
            }

            fn addPosition(self: *Vector, entry: *Entry, position: u16) Error!void {
                if (self.pos_len == max_positions) return error.TextCapacity;
                self.positions[self.pos_len] = position;
                self.pos_len += 1;
                entry.pos_count += 1;
            }

            fn positionsOf(self: *const Vector, entry: Entry) []const u16 {
                return self.positions[entry.pos_start..][0..entry.pos_count];
            }
        };

        /// tsCompareString: bytes, then shorter first.
        fn compareLexemes(a: []const u8, b: []const u8) std.math.Order {
            const common = @min(a.len, b.len);
            for (a[0..common], b[0..common]) |x, y| {
                if (x != y) return if (x < y) .lt else .gt;
            }
            return std.math.order(a.len, b.len);
        }

        /// Stable insertion sort of positions, by position value (weight bits
        /// ignored) or by the whole u16. Written by hand because std.sort
        /// passes its context struct (slice plus context) by value, which
        /// the native SB0 backend cannot decompose into registers.
        fn sortPositions(items: []u16, by_value: bool) void {
            var sorted: usize = 1;
            while (sorted < items.len) : (sorted += 1) {
                var at = sorted;
                while (at > 0) : (at -= 1) {
                    const less = if (by_value) positionValue(items[at]) < positionValue(items[at - 1]) else items[at] < items[at - 1];
                    if (!less) break;
                    std.mem.swap(u16, &items[at], &items[at - 1]);
                }
            }
        }

        fn positionValue(position: u16) u16 {
            return position & 0x3fff;
        }

        /// Writes a vector's canonical text (tsvectorout) after sorting,
        /// merging duplicate lexemes and their positions (uniqueentry,
        /// uniquePos: sorted, equal positions keep the highest weight, at
        /// most 256 per lexeme).
        /// tsvector entry order: lexeme bytes, then original position.
        fn entryLess(vector: *const Vector, a: Entry, b: Entry) bool {
            const order = compareLexemes(vector.lexeme(a), vector.lexeme(b));
            if (order != .eq) return order == .lt;
            return a.pos_start < b.pos_start;
        }

        pub fn writeVector(vector: *Vector, out: *Out, cap: usize) Error!void {
            // Insertion sort by hand: std.sort passes its context (the slice
            // plus this vector pointer, 24 bytes) by value, which the native
            // SB0 backend cannot decompose into registers.
            var sorted: usize = 1;
            while (sorted < vector.count) : (sorted += 1) {
                var at = sorted;
                while (at > 0 and entryLess(vector, vector.entries[at], vector.entries[at - 1])) : (at -= 1) {
                    std.mem.swap(Entry, &vector.entries[at], &vector.entries[at - 1]);
                }
            }
            out.len = 0;
            var index: usize = 0;
            var first = true;
            while (index < vector.count) {
                var end = index + 1;
                while (end < vector.count and compareLexemes(vector.lexeme(vector.entries[index]), vector.lexeme(vector.entries[end])) == .eq) end += 1;
                if (!first) try out.put(" ");
                first = false;
                try out.put("'");
                for (vector.lexeme(vector.entries[index])) |byte| {
                    if (byte == '\'' or byte == '\\') try out.put(&[_]u8{byte});
                    try out.put(&[_]u8{byte});
                }
                try out.put("'");
                // Gather this lexeme's positions.
                var merged: [max_positions]u16 = undefined;
                var count: usize = 0;
                for (vector.entries[index..end]) |entry| for (vector.positionsOf(entry)) |position| {
                    merged[count] = position;
                    count += 1;
                };
                sortPositions(merged[0..count], true);
                var kept: usize = 0;
                for (merged[0..count]) |position| {
                    // uniquePos stops after position 16383.
                    if (kept != 0 and positionValue(merged[kept - 1]) == max_position) break;
                    if (kept != 0 and positionValue(merged[kept - 1]) == positionValue(position)) {
                        if (position >> 14 > merged[kept - 1] >> 14) merged[kept - 1] = position;
                        continue;
                    }
                    if (kept == cap) break;
                    merged[kept] = position;
                    kept += 1;
                }
                for (merged[0..kept], 0..) |position, at| {
                    try out.put(if (at == 0) ":" else ",");
                    try out.number(positionValue(position));
                    switch (position >> 14) {
                        3 => try out.put("A"),
                        2 => try out.put("B"),
                        1 => try out.put("C"),
                        else => {},
                    }
                }
                index = end;
            }
        }

        fn space(byte: u8) bool {
            return byte == ' ' or (byte >= 9 and byte <= 13);
        }

        /// gettoken_tsvector (with `operators` as tsquery's delimiters):
        /// one lexeme into `word`; positions into the vector when given.
        const Token = struct { word_len: usize, end: usize };

        fn lexemeToken(input: []const u8, start: usize, word: *[text_bytes]u8, operators: bool, vector: ?*Vector, entry: ?*Entry) Error!?Token {
            var at = start;
            var len: usize = 0;
            const Mode = enum { wait_word, end_word, end_complex, char_complex };
            var mode: Mode = .wait_word;
            while (true) {
                const done = at >= input.len;
                const byte: u8 = if (done) 0 else input[at];
                switch (mode) {
                    .wait_word => {
                        if (done) return null;
                        if (byte == '\'') {
                            mode = .end_complex;
                        } else if (byte == '\\') {
                            at += 1;
                            if (at >= input.len) return error.Syntax;
                            const width = utf8Length(input, at);
                            if (width > text_bytes - len) return error.TextCapacity;
                            @memcpy(word[len..][0..width], input[at..][0..width]);
                            len += width;
                            at += width;
                            mode = .end_word;
                            continue;
                        } else if (operators and isOperator(byte)) {
                            return error.Syntax;
                        } else if (!space(byte)) {
                            // The first character is the word's, even a colon.
                            const width = utf8Length(input, at);
                            if (width > text_bytes - len) return error.TextCapacity;
                            @memcpy(word[len..][0..width], input[at..][0..width]);
                            len += width;
                            at += width;
                            mode = .end_word;
                            continue;
                        }
                        at += 1;
                    },
                    .end_word => {
                        if (byte == '\\' and !done) {
                            at += 1;
                            if (at >= input.len) return error.Syntax;
                            const width = utf8Length(input, at);
                            if (width > text_bytes - len) return error.TextCapacity;
                            @memcpy(word[len..][0..width], input[at..][0..width]);
                            len += width;
                            at += width;
                        } else if (done or space(byte) or (operators and isOperator(byte))) {
                            if (len == 0) return error.Syntax;
                            return .{ .word_len = len, .end = at };
                        } else if (byte == ':') {
                            if (len == 0) return error.Syntax;
                            if (operators) return .{ .word_len = len, .end = at };
                            return .{ .word_len = len, .end = try positionInfo(input, at + 1, vector.?, entry.?) };
                        } else {
                            const width = utf8Length(input, at);
                            if (width > text_bytes - len) return error.TextCapacity;
                            @memcpy(word[len..][0..width], input[at..][0..width]);
                            len += width;
                            at += width;
                        }
                    },
                    .end_complex => {
                        if (done) return error.Syntax;
                        if (byte == '\'') {
                            mode = .char_complex;
                            at += 1;
                        } else if (byte == '\\') {
                            at += 1;
                            if (at >= input.len) return error.Syntax;
                            const width = utf8Length(input, at);
                            if (width > text_bytes - len) return error.TextCapacity;
                            @memcpy(word[len..][0..width], input[at..][0..width]);
                            len += width;
                            at += width;
                        } else {
                            const width = utf8Length(input, at);
                            if (width > text_bytes - len) return error.TextCapacity;
                            @memcpy(word[len..][0..width], input[at..][0..width]);
                            len += width;
                            at += width;
                        }
                    },
                    .char_complex => {
                        if (byte == '\'' and !done) {
                            if (len == text_bytes) return error.TextCapacity;
                            word[len] = '\'';
                            len += 1;
                            at += 1;
                            mode = .end_complex;
                        } else {
                            if (len == 0) return error.Syntax;
                            if (operators) return .{ .word_len = len, .end = at };
                            if (byte == ':' and !done) return .{ .word_len = len, .end = try positionInfo(input, at + 1, vector.?, entry.?) };
                            return .{ .word_len = len, .end = at };
                        }
                    },
                }
            }
        }

        /// INPOSINFO / WAITPOSDELIM: `n[weight],...` after a lexeme's colon.
        fn positionInfo(input: []const u8, start: usize, vector: *Vector, entry: *Entry) Error!usize {
            var at = start;
            while (true) {
                if (at >= input.len or input[at] < '0' or input[at] > '9') return error.Syntax;
                var value: u64 = 0;
                while (at < input.len and input[at] >= '0' and input[at] <= '9') : (at += 1) value = @min(value * 10 + (input[at] - '0'), 0xffff_ffff);
                if (value == 0) return error.Syntax;
                var position: u16 = @intCast(@min(value, max_position));
                var weighted = false;
                while (at < input.len) {
                    const byte = input[at];
                    const weight: ?u16 = switch (byte) {
                        'a', 'A', '*' => 3,
                        'b', 'B' => 2,
                        'c', 'C' => 1,
                        'd', 'D' => 0,
                        else => null,
                    };
                    if (weight) |w| {
                        if (weighted and position >> 14 != 0) return error.Syntax;
                        position = (position & 0x3fff) | (w << 14);
                        weighted = true;
                        at += 1;
                    } else break;
                }
                try vector.addPosition(entry, position);
                if (at < input.len and input[at] == ',') {
                    at += 1;
                    continue;
                }
                if (at >= input.len or space(input[at])) return at;
                return error.Syntax;
            }
        }

        fn isOperator(byte: u8) bool {
            return byte == '!' or byte == '&' or byte == '|' or byte == '(' or byte == ')' or byte == '<';
        }

        /// tsvector_in into `vector` (unsorted, as written).
        pub fn readVector(input: []const u8, vector: *Vector) Error!void {
            vector.* = .{ .bytes = undefined, .entries = undefined, .positions = undefined };
            var word: [text_bytes]u8 = undefined;
            var at: usize = 0;
            while (true) {
                // Positions belong to the entry added for this lexeme: add it
                // first, then fill its text.
                const mark_bytes = vector.bytes_len;
                const entry = try vector.add("");
                const token = (try lexemeToken(input, at, &word, false, vector, entry)) orelse {
                    vector.count -= 1;
                    vector.bytes_len = mark_bytes;
                    return;
                };
                if (token.word_len > text_bytes - vector.bytes_len) return error.TextCapacity;
                @memcpy(vector.bytes[vector.bytes_len..][0..token.word_len], word[0..token.word_len]);
                entry.len = @intCast(token.word_len);
                vector.bytes_len += token.word_len;
                at = token.end;
            }
        }

        /// tsvector_in: canonical text of `input` (42601 on bad syntax).
        pub fn vectorIn(input: []const u8, out: *Out) Error!void {
            var vector: Vector = undefined;
            try readVector(input, &vector);
            try writeVector(&vector, out, max_positions_per_lexeme);
        }

        /// Folds ASCII letters (the simple dictionary under C ctype).
        fn lowerInto(word: []const u8, buffer: []u8) []const u8 {
            for (word, 0..) |byte, index| buffer[index] = if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
            return buffer[0..word.len];
        }

        /// parsetext with `simple`: each indexed token is one lexeme at the
        /// next position.
        fn parseText(text: []const u8, vector: *Vector, control: ?*types.ExecutionControl) Error!void {
            var parser = Parser.init(text);
            var position: usize = 0;
            var buffer: [text_bytes]u8 = undefined;
            while (try parser.next()) |token| {
                if (control) |active| try active.checkpoint();
                if (!simpleIndexes(token.kind)) continue;
                if (token.bytes.len >= max_word) continue;
                position += 1;
                const lexeme = lowerInto(token.bytes, &buffer);
                const entry = try vector.add(lexeme);
                // Positions beyond 16383 are recorded as 16383.
                try vector.addPosition(entry, @intCast(@min(position, max_position)));
            }
        }

        /// to_tsvector(config, text).
        pub fn toVector(text: []const u8, out: *Out, control: ?*types.ExecutionControl) Error!void {
            var vector: Vector = .{};
            try parseText(text, &vector, control);
            // uniqueWORD keeps at most MAXNUMPOS - 1 positions per word.
            try writeVector(&vector, out, max_positions_per_lexeme - 1);
        }

        // ---- tsquery ----------------------------------------------------

        pub const Kind = enum(u8) { operand, not, @"and", @"or", phrase, void };
        pub const Node = struct { kind: Kind = .operand, left: u16 = 0, right: u16 = 0, distance: u16 = 0, weight: u8 = 0, prefix: bool = false, start: u32 = 0, len: u32 = 0 };

        pub const Query = struct {
            nodes: [max_nodes]Node = undefined,
            count: usize = 0,
            bytes: [text_bytes]u8 = undefined,
            bytes_len: usize = 0,
            root: ?u16 = null,

            fn node(self: *Query, value: Node) Error!u16 {
                if (self.count == max_nodes) return error.TextCapacity;
                self.nodes[self.count] = value;
                self.count += 1;
                return @intCast(self.count - 1);
            }

            fn operand(self: *Query, word: []const u8, weight: u8, prefix: bool) Error!u16 {
                if (word.len > text_bytes - self.bytes_len) return error.TextCapacity;
                @memcpy(self.bytes[self.bytes_len..][0..word.len], word);
                const id = try self.node(.{ .weight = weight, .prefix = prefix, .start = @intCast(self.bytes_len), .len = @intCast(word.len) });
                self.bytes_len += word.len;
                return id;
            }

        };

        fn priority(kind: Kind) u8 {
            return switch (kind) {
                .not => 4,
                .phrase => 3,
                .@"and" => 2,
                .@"or" => 1,
                .operand, .void => 5,
            };
        }

        /// How operands become query nodes: as written (tsquery_in) or
        /// through the configuration (to_tsquery and its siblings, with the
        /// operator joining the words of one operand).
        pub const Morph = enum { as_is, phrase, @"and" };

        /// An operand: as written, or each indexed word of it joined by
        /// `morph`'s operator (pushval_morph: words of one operand are
        /// left-nested); one without words is a stop-word placeholder that
        /// cleanup() removes.
        fn pushOperand(query: *Query, text: []const u8, weight: u8, prefix: bool, morph: Morph) Error!u16 {
            if (morph == .as_is) return try query.operand(text, weight, prefix);
            var vector: Vector = .{};
            try parseText(text, &vector, null);
            if (vector.count == 0) return query.node(.{ .kind = .void });
            var result: ?u16 = null;
            for (vector.entries[0..vector.count]) |entry| {
                const id = try query.operand(vector.lexeme(entry), weight, prefix);
                result = if (result) |left| try query.node(.{ .kind = if (morph == .@"and") .@"and" else .phrase, .left = left, .right = id, .distance = 1 }) else id;
            }
            return result.?;
        }

        const Adjust = struct { left: usize = 0, right: usize = 0 };

        /// clean_stopword_intree: drops placeholders, folding phrase
        /// distances of removed parts into the neighbouring phrase operator.
        fn cleanup(query: *Query, id: u16, adjust: *Adjust, depth: usize) Error!?u16 {
            if (depth > depth_limit + 2) return error.StatementTooComplex;
            adjust.* = .{};
            const n = &query.nodes[id];
            switch (n.kind) {
                .operand => return id,
                .void => return null,
                .not => {
                    n.right = (try cleanup(query, n.right, adjust, depth + 1)) orelse return null;
                    return id;
                },
                else => {
                    var left: Adjust = .{};
                    var right: Adjust = .{};
                    const kept_left = try cleanup(query, n.left, &left, depth + 1);
                    const kept_right = try cleanup(query, n.right, &right, depth + 1);
                    const phrase_op = n.kind == .phrase;
                    const distance: usize = if (phrase_op) n.distance else 0;
                    if (kept_left == null and kept_right == null) {
                        const both = if (phrase_op) left.left + distance + right.left else @max(left.left, right.left);
                        adjust.* = .{ .left = both, .right = both };
                        return null;
                    }
                    if (kept_left == null) {
                        adjust.* = if (phrase_op) .{ .left = left.left + distance + right.left, .right = right.right } else .{ .left = right.left, .right = right.right };
                        return kept_right;
                    }
                    if (kept_right == null) {
                        adjust.* = if (phrase_op) .{ .left = left.left, .right = left.right + distance + right.right } else .{ .left = left.left, .right = left.right };
                        return kept_left;
                    }
                    n.left = kept_left.?;
                    n.right = kept_right.?;
                    if (phrase_op) {
                        n.distance = @intCast(@min(@as(usize, n.distance) + left.right + right.left, 0xffff));
                        adjust.* = .{ .left = left.left, .right = right.right };
                    }
                    return id;
                },
            }
        }

        /// parse_tsquery: `!` > `<->` / `<N>` > `&` > `|`, parentheses,
        /// operands with `:` weights (abcd) and `*` (prefix).
        pub fn readQuery(input: []const u8, query: *Query, morph: Morph) Error!void {
            query.count = 0;
            query.bytes_len = 0;
            query.root = null;
            var operands: [max_nodes]u16 = undefined;
            var operand_count: usize = 0;
            const Op = struct { kind: Kind, distance: u16, open: bool };
            var operators: [max_nodes]Op = undefined;
            var operator_count: usize = 0;
            var expect_operand = true;
            var depth: usize = 0;
            var at: usize = 0;
            var word: [text_bytes]u8 = undefined;
            const Reduce = struct {
                fn one(q: *Query, ops: []Op, op_count: *usize, vals: []u16, val_count: *usize) Error!void {
                    const op = ops[op_count.* - 1];
                    op_count.* -= 1;
                    if (op.kind == .not) {
                        if (val_count.* < 1) return error.Syntax;
                        vals[val_count.* - 1] = try q.node(.{ .kind = .not, .right = vals[val_count.* - 1] });
                        return;
                    }
                    if (val_count.* < 2) return error.Syntax;
                    const right = vals[val_count.* - 1];
                    const left = vals[val_count.* - 2];
                    val_count.* -= 1;
                    vals[val_count.* - 1] = try q.node(.{ .kind = op.kind, .left = left, .right = right, .distance = op.distance });
                }
            };
            while (true) {
                while (at < input.len and space(input[at])) at += 1;
                if (at >= input.len) break;
                const byte = input[at];
                if (expect_operand) {
                    if (byte == '!') {
                        at += 1;
                        if (operator_count == max_nodes) return error.TextCapacity;
                        operators[operator_count] = .{ .kind = .not, .distance = 0, .open = false };
                        operator_count += 1;
                        continue;
                    }
                    if (byte == '(') {
                        at += 1;
                        depth += 1;
                        if (depth > depth_limit) return error.StatementTooComplex;
                        if (operator_count == max_nodes) return error.TextCapacity;
                        operators[operator_count] = .{ .kind = .operand, .distance = 0, .open = true };
                        operator_count += 1;
                        continue;
                    }
                    const token = (try lexemeToken(input, at, &word, true, null, null)) orelse return error.Syntax;
                    at = token.end;
                    var weight: u8 = 0;
                    var prefix = false;
                    if (at < input.len and input[at] == ':') {
                        at += 1;
                        while (at < input.len) : (at += 1) switch (input[at]) {
                            '*' => prefix = true,
                            'a', 'A' => weight |= 1 << 3,
                            'b', 'B' => weight |= 1 << 2,
                            'c', 'C' => weight |= 1 << 1,
                            'd', 'D' => weight |= 1,
                            else => break,
                        };
                    }
                    operands[operand_count] = try pushOperand(query, word[0..token.word_len], weight, prefix, morph);
                    operand_count += 1;
                    expect_operand = false;
                    continue;
                }
                // An operator or a closing parenthesis.
                var kind: Kind = undefined;
                var distance: u16 = 0;
                if (byte == ')') {
                    at += 1;
                    if (depth == 0) return error.Syntax;
                    depth -= 1;
                    while (operator_count != 0 and !operators[operator_count - 1].open) try Reduce.one(query, &operators, &operator_count, &operands, &operand_count);
                    if (operator_count == 0) return error.Syntax;
                    operator_count -= 1;
                    // NOTs before the group apply to it.
                    while (operator_count != 0 and operators[operator_count - 1].kind == .not and !operators[operator_count - 1].open) try Reduce.one(query, &operators, &operator_count, &operands, &operand_count);
                    continue;
                } else if (byte == '&') {
                    kind = .@"and";
                    at += 1;
                } else if (byte == '|') {
                    kind = .@"or";
                    at += 1;
                } else if (byte == '<') {
                    // <-> or <N> (0 through 16384).
                    at += 1;
                    if (at < input.len and input[at] == '-') {
                        at += 1;
                        distance = 1;
                    } else {
                        var value: u32 = 0;
                        var digits: usize = 0;
                        while (at < input.len and input[at] >= '0' and input[at] <= '9') : (at += 1) {
                            value = @min(value * 10 + (input[at] - '0'), 100000);
                            digits += 1;
                        }
                        if (digits == 0) return error.Syntax;
                        if (value > max_position + 1) return error.InvalidParameterValue;
                        distance = @intCast(value);
                    }
                    if (at >= input.len or input[at] != '>') return error.Syntax;
                    at += 1;
                    kind = .phrase;
                } else return error.Syntax;
                // Operators of a NOT bind to the operand just read.
                while (operator_count != 0 and operators[operator_count - 1].kind == .not and !operators[operator_count - 1].open) try Reduce.one(query, &operators, &operator_count, &operands, &operand_count);
                while (operator_count != 0 and !operators[operator_count - 1].open and priority(operators[operator_count - 1].kind) >= priority(kind)) try Reduce.one(query, &operators, &operator_count, &operands, &operand_count);
                if (operator_count == max_nodes) return error.TextCapacity;
                operators[operator_count] = .{ .kind = kind, .distance = distance, .open = false };
                operator_count += 1;
                expect_operand = true;
            }
            if (depth != 0) return error.Syntax;
            if (expect_operand and (operator_count != 0 or operand_count != 0)) return error.Syntax;
            while (operator_count != 0) {
                if (operators[operator_count - 1].open) return error.Syntax;
                try Reduce.one(query, &operators, &operator_count, &operands, &operand_count);
            }
            if (operand_count == 0) return;
            if (operand_count != 1) return error.Syntax;
            var adjust: Adjust = .{};
            query.root = if (morph == .as_is) operands[0] else try cleanup(query, operands[0], &adjust, 0);
        }

        /// infix(): the canonical tsquery text.
        pub fn writeQuery(query: *const Query, out: *Out) Error!void {
            out.len = 0;
            const root = query.root orelse return;
            try infix(query, root, 0, false, out, 0);
        }

        fn infix(query: *const Query, id: u16, parent: u8, right_phrase: bool, out: *Out, depth: usize) Error!void {
            if (depth > depth_limit + 2) return error.StatementTooComplex;
            const n = query.nodes[id];
            switch (n.kind) {
                .void => return error.UnsupportedStatement,
                .operand => {
                    try out.put("'");
                    for (query.bytes[n.start..][0..n.len]) |byte| {
                        if (byte == '\'' or byte == '\\') try out.put(&[_]u8{byte});
                        try out.put(&[_]u8{byte});
                    }
                    try out.put("'");
                    if (n.weight != 0 or n.prefix) {
                        try out.put(":");
                        if (n.prefix) try out.put("*");
                        if (n.weight & 8 != 0) try out.put("A");
                        if (n.weight & 4 != 0) try out.put("B");
                        if (n.weight & 2 != 0) try out.put("C");
                        if (n.weight & 1 != 0) try out.put("D");
                    }
                },
                .not => {
                    const own = priority(.not);
                    if (own < parent) try out.put("( ");
                    try out.put("!");
                    try infix(query, n.right, own, false, out, depth + 1);
                    if (own < parent) try out.put(" )");
                },
                else => {
                    const own = priority(n.kind);
                    const parens = own < parent or (n.kind == .phrase and right_phrase);
                    if (parens) try out.put("( ");
                    try infix(query, n.left, own, false, out, depth + 1);
                    switch (n.kind) {
                        .@"or" => try out.put(" | "),
                        .@"and" => try out.put(" & "),
                        else => if (n.distance != 1) {
                            try out.put(" <");
                            try out.number(n.distance);
                            try out.put("> ");
                        } else try out.put(" <-> "),
                    }
                    try infix(query, n.right, own, n.kind == .phrase, out, depth + 1);
                    if (parens) try out.put(" )");
                },
            }
        }

        /// tsquery_in.
        pub fn queryIn(input: []const u8, out: *Out) Error!void {
            var query: Query = .{};
            try readQuery(input, &query, .as_is);
            try writeQuery(&query, out);
        }

        /// to_tsquery (phrase), plainto_tsquery (and: the whole text is one
        /// operand) and phraseto_tsquery (phrase: one operand).
        pub fn toQuery(text: []const u8, which: enum { to, plain, phrase }, out: *Out) Error!void {
            var query: Query = .{};
            switch (which) {
                .to => try readQuery(text, &query, .phrase),
                .plain, .phrase => {
                    var adjust: Adjust = .{};
                    query.root = try cleanup(&query, try pushOperand(&query, text, 0, false, if (which == .plain) .@"and" else .phrase), &adjust, 0);
                },
            }
            try writeQuery(&query, out);
        }

        // ---- @@ -----------------------------------------------------------

        const Ternary = enum { no, yes, maybe };
        /// ExecPhraseData: positions (in `arena`), width and negation.
        const Phrase = struct { start: usize = 0, count: usize = 0, width: usize = 0, negate: bool = false };

        const Matcher = struct {
            vector: *const Vector,
            query: *const Query,
            arena: [max_positions * 4]u16 = undefined,
            used: usize = 0,
            control: ?*types.ExecutionControl,

            fn reserve(self: *Matcher, count: usize) Error!usize {
                if (count > self.arena.len - self.used) return error.ProgramLimitExceeded;
                const start = self.used;
                self.used += count;
                return start;
            }

            /// Entries matching an operand: exact, or every lexeme with its
            /// prefix.
            fn entryRange(self: *const Matcher, n: Node) struct { low: usize, high: usize } {
                const wanted = self.query.bytes[n.start..][0..n.len];
                var low: usize = 0;
                while (low < self.vector.count and compareLexemes(self.vector.lexeme(self.vector.entries[low]), wanted) == .lt) low += 1;
                var high = low;
                while (high < self.vector.count) : (high += 1) {
                    const lexeme = self.vector.lexeme(self.vector.entries[high]);
                    if (n.prefix) {
                        if (lexeme.len < wanted.len or !std.mem.eql(u8, lexeme[0..wanted.len], wanted)) break;
                    } else if (!std.mem.eql(u8, lexeme, wanted)) break;
                }
                return .{ .low = low, .high = high };
            }

            /// checkcondition_str / checkclass_str.
            fn operand(self: *Matcher, n: Node, data: ?*Phrase) Error!Ternary {
                const range = self.entryRange(n);
                if (range.low == range.high) return .no;
                var result: Ternary = .no;
                if (data) |out| {
                    out.start = self.used;
                    out.count = 0;
                }
                for (self.vector.entries[range.low..range.high]) |entry| {
                    const positions = self.vector.positionsOf(entry);
                    if (positions.len == 0) {
                        // A lexeme without positions: unknown in a phrase.
                        if (data) |out| {
                            self.used = out.start;
                            out.count = 0;
                            return .maybe;
                        }
                        return .yes;
                    }
                    for (positions) |position| {
                        if (n.weight != 0 and n.weight & (@as(u8, 1) << @intCast(position >> 14)) == 0) continue;
                        if (data) |out| {
                            _ = try self.reserve(1);
                            self.arena[out.start + out.count] = position & 0x3fff;
                            out.count += 1;
                        }
                        result = .yes;
                    }
                    if (result == .yes and data == null) return .yes;
                }
                if (data) |out| {
                    if (out.count != 0) {
                        // Prefix matches merge positions: sorted, unique.
                        const list = self.arena[out.start..][0..out.count];
                        sortPositions(list, false);
                        var kept: usize = 0;
                        for (list) |position| {
                            if (kept != 0 and list[kept - 1] == position) continue;
                            list[kept] = position;
                            kept += 1;
                        }
                        out.count = kept;
                        self.used = out.start + kept;
                        return .yes;
                    }
                    return .no;
                }
                return result;
            }

            const both: u8 = 1;
            const left_only: u8 = 2;
            const right_only: u8 = 4;

            /// TS_phrase_output.
            fn output(self: *Matcher, data: ?*Phrase, left: Phrase, right: Phrase, emit: u8, left_offset: usize, right_offset: usize) Error!Ternary {
                var li: usize = 0;
                var ri: usize = 0;
                if (data) |out| {
                    out.start = self.used;
                    out.count = 0;
                }
                while (li < left.count or ri < right.count) {
                    var lpos: usize = std.math.maxInt(usize);
                    var rpos: usize = std.math.maxInt(usize);
                    if (li < left.count) {
                        lpos = self.arena[left.start + li] + left_offset;
                    } else if (emit & right_only == 0) break;
                    if (ri < right.count) {
                        rpos = self.arena[right.start + ri] + right_offset;
                    } else if (emit & left_only == 0) break;
                    var emitted: usize = 0;
                    if (lpos < rpos) {
                        if (emit & left_only != 0) emitted = lpos;
                        li += 1;
                    } else if (lpos == rpos) {
                        if (emit & both != 0) emitted = rpos;
                        li += 1;
                        ri += 1;
                    } else {
                        if (emit & right_only != 0) emitted = rpos;
                        ri += 1;
                    }
                    if (emitted > 0) {
                        if (data) |out| {
                            _ = try self.reserve(1);
                            self.arena[out.start + out.count] = @intCast(@min(emitted, 0xffff));
                            out.count += 1;
                        } else return .yes;
                    }
                }
                if (data) |out| if (out.count > 0) return .yes;
                return .no;
            }

            /// TS_phrase_execute.
            fn phrase(self: *Matcher, id: u16, data: ?*Phrase, depth: usize) Error!Ternary {
                if (depth > depth_limit + 2) return error.StatementTooComplex;
                if (self.control) |active| try active.checkpoint();
                const n = self.query.nodes[id];
                switch (n.kind) {
                    .void => return .no,
                    .operand => return self.operand(n, data),
                    .not => {
                        const out = data orelse return error.StatementTooComplex;
                        switch (try self.phrase(n.right, out, depth + 1)) {
                            .no => {
                                out.negate = true;
                                return .yes;
                            },
                            .yes => {
                                if (out.count > 0) {
                                    out.negate = !out.negate;
                                    return .yes;
                                }
                                if (out.negate) {
                                    out.negate = false;
                                    return .no;
                                }
                                return .no;
                            },
                            .maybe => return .maybe,
                        }
                    },
                    .phrase, .@"and" => {
                        const mark = self.used;
                        defer if (data == null) {
                            self.used = mark;
                        };
                        var left: Phrase = .{};
                        var right: Phrase = .{};
                        const lmatch = try self.phrase(n.left, &left, depth + 1);
                        if (lmatch == .no) return .no;
                        const rmatch = try self.phrase(n.right, &right, depth + 1);
                        if (rmatch == .no) return .no;
                        if (lmatch == .maybe or rmatch == .maybe) return .maybe;
                        var left_offset: usize = 0;
                        var right_offset: usize = 0;
                        if (n.kind == .phrase) {
                            left_offset = n.distance + right.width;
                            if (data) |out| out.width = n.distance + left.width + right.width;
                        } else {
                            const widest = @max(left.width, right.width);
                            left_offset = widest - left.width;
                            right_offset = widest - right.width;
                            if (data) |out| out.width = widest;
                        }
                        if (left.negate and right.negate) {
                            _ = try self.output(data, left, right, both | left_only | right_only, left_offset, right_offset);
                            if (data) |out| out.negate = true;
                            return .yes;
                        }
                        if (left.negate) return self.output(data, left, right, right_only, left_offset, right_offset);
                        if (right.negate) return self.output(data, left, right, left_only, left_offset, right_offset);
                        return self.output(data, left, right, both, left_offset, right_offset);
                    },
                    .@"or" => {
                        const out = data orelse return error.StatementTooComplex;
                        var left: Phrase = .{};
                        var right: Phrase = .{};
                        const lmatch = try self.phrase(n.left, &left, depth + 1);
                        const rmatch = try self.phrase(n.right, &right, depth + 1);
                        if (lmatch == .no and rmatch == .no) return .no;
                        if (lmatch == .maybe or rmatch == .maybe) return .maybe;
                        if (lmatch == .no) left.width = 0;
                        if (rmatch == .no) right.width = 0;
                        const widest = @max(left.width, right.width);
                        out.width = widest;
                        if (left.negate and right.negate) {
                            _ = try self.output(out, left, right, both, widest - left.width, widest - right.width);
                            out.negate = true;
                            return .yes;
                        }
                        if (left.negate) {
                            _ = try self.output(out, left, right, left_only, widest - left.width, widest - right.width);
                            out.negate = true;
                            return .yes;
                        }
                        if (right.negate) {
                            _ = try self.output(out, left, right, right_only, widest - left.width, widest - right.width);
                            out.negate = true;
                            return .yes;
                        }
                        return self.output(out, left, right, both | left_only | right_only, widest - left.width, widest - right.width);
                    },
                }
            }

            /// TS_execute_recurse (no TS_EXEC_PHRASE_NO_POS).
            fn execute(self: *Matcher, id: u16, depth: usize) Error!Ternary {
                if (depth > depth_limit + 2) return error.StatementTooComplex;
                if (self.control) |active| try active.checkpoint();
                const n = self.query.nodes[id];
                switch (n.kind) {
                    .void => return .no,
                    .operand => return self.operand(n, null),
                    .not => return switch (try self.execute(n.right, depth + 1)) {
                        .no => .yes,
                        .yes => .no,
                        .maybe => .maybe,
                    },
                    .@"and" => {
                        const lmatch = try self.execute(n.left, depth + 1);
                        if (lmatch == .no) return .no;
                        return switch (try self.execute(n.right, depth + 1)) {
                            .no => .no,
                            .yes => lmatch,
                            .maybe => .maybe,
                        };
                    },
                    .@"or" => {
                        const lmatch = try self.execute(n.left, depth + 1);
                        if (lmatch == .yes) return .yes;
                        return switch (try self.execute(n.right, depth + 1)) {
                            .no => lmatch,
                            .yes => .yes,
                            .maybe => .maybe,
                        };
                    },
                    .phrase => {
                        const mark = self.used;
                        defer self.used = mark;
                        return switch (try self.phrase(id, null, depth + 1)) {
                            .yes => .yes,
                            else => .no,
                        };
                    },
                }
            }
        };

        /// ts_match_vq: tsvector @@ tsquery over canonical texts. An empty
        /// query matches nothing.
        pub fn matches(vector_text: []const u8, query_text: []const u8, control: ?*types.ExecutionControl) Error!bool {
            var vector: Vector = undefined;
            try readVector(vector_text, &vector);
            var query: Query = undefined;
            try readQuery(query_text, &query, .as_is);
            const root = query.root orelse return false;
            var matcher: Matcher = .{ .vector = &vector, .query = &query, .control = control };
            return try matcher.execute(root, 0) != .no;
        }

        /// A stored value is canonical: its text re-reads to itself.
        pub fn canonicalVector(text: []const u8) bool {
            var out: Out = .{};
            vectorIn(text, &out) catch return false;
            return std.mem.eql(u8, out.slice(), text);
        }

        pub const configByName = configByNameImpl;

        pub fn canonicalQuery(text: []const u8) bool {
            var out: Out = .{};
            queryIn(text, &out) catch return false;
            return std.mem.eql(u8, out.slice(), text);
        }
    };
}
