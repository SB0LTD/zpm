//! POSIX regular expressions (Layer 0), conformance lane B11 "text":
//! PostgreSQL's advanced regular expressions (ARE; regcomp.c, regc_lex.c)
//! for `~ ~* !~ !~*`, SIMILAR TO (similar_to_escape) and regexp_like.
//!
//! Patterns compile into a bounded Thompson-NFA program (at most `states`
//! instructions, Config.regex_states) and match by Pike-VM simulation:
//! work is linear in text length times program size, every text position
//! is one ExecutionControl checkpoint, and nothing allocates. Whether a
//! match exists does not depend on greediness, so the operators and
//! regexp_like are exact; match positions and submatches (substring,
//! regexp_replace, ...) are not provided.
//!
//! Syntax: the whole ARE language except back references (0A000) and
//! BREs (option `b`, 0A000): literals and every escape (\a \b \B \cX \e
//! \f \n \r \t \uXXXX \UXXXXXXXX \v \xHH... and octal \0, \NN, \NNN),
//! `.`, bracket expressions with ranges, [:class:], [.element.] (single
//! characters and the POSIX names) and [=x=], \d \s \w \D \S \W (also
//! inside brackets), groups (capturing, `(?:`), alternation, `* + ?
//! {m} {m,} {m,n}` and their non-greedy forms (bounds up to 255),
//! constraints `^ $ \A \Z \m \M \y \Y [[:<:]] [[:>:]]`, lookahead and
//! lookbehind `(?= (?! (?<= (?<!` (nested at most max_look_depth deep,
//! 0A000 beyond), comments `(?#...)`, directors `***:` and `***=` and the
//! leading embedded options `(?bcefimnpqstwx)`. The embedded option `e`
//! selects plain ERE syntax; BREs (embedded `b`, function options `b` and
//! `e`) are 0A000.
//!
//! Character semantics are the C strategy of regc_pg_locale.c (this
//! database's collation is C): classes contain ASCII characters only
//! (cntrl also 0x80-0x9f), and case-insensitive matching folds ASCII
//! letters only. Malformed patterns are 2201B (InvalidRegularExpression);
//! a program beyond `states` instructions is 54000.
const types = @import("types.sig");
const Error = types.Error;

pub const Flags = struct {
    icase: bool = false,
    /// `.` and `[^...]` do not match a newline (REG_NLSTOP).
    nlstop: bool = false,
    /// `^` and `$` also match after / before a newline (REG_NLANCH).
    nlanch: bool = false,
    /// Expanded syntax: white space and #-comments are ignored.
    expanded: bool = false,
    /// The whole pattern is a literal string.
    quote: bool = false,
    /// Plain ERE syntax: no ARE escapes, extensions or embedded options.
    ere: bool = false,
};

/// parse_re_flags: the option letters of regexp_like and its siblings over
/// `base`. `g` is reported for the caller to reject; any other unknown
/// letter is 22023. `b` selects BREs, and so does `e`: parse_re_flags sets
/// REG_EXTENDED and then clears REG_ADVANCED, which includes it. BREs are
/// 0A000 unless a later `q` makes the pattern literal.
pub fn parseOptions(options: []const u8, base: Flags) Error!struct { flags: Flags, global: bool } {
    var flags = base;
    var global = false;
    var bre = false;
    for (options) |option| switch (option) {
        'g' => global = true,
        'b', 'e' => {
            bre = true;
            flags.quote = false;
        },
        'c' => flags.icase = false,
        'i' => flags.icase = true,
        'm', 'n' => {
            flags.nlstop = true;
            flags.nlanch = true;
        },
        'p' => {
            flags.nlstop = true;
            flags.nlanch = false;
        },
        'q' => {
            flags.quote = true;
            bre = false;
        },
        's' => {
            flags.nlstop = false;
            flags.nlanch = false;
        },
        't' => flags.expanded = false,
        'w' => {
            flags.nlstop = false;
            flags.nlanch = true;
        },
        'x' => flags.expanded = true,
        else => return error.InvalidParameterValue,
    };
    // regexp_like reports `g` (22023) before compiling.
    if (bre and !global) return error.UnsupportedStatement;
    return .{ .flags = flags, .global = global };
}

/// Lookaround constraints nested deeper than this are 0A000.
pub const max_look_depth = 3;
/// RE_DUP_MAX: the largest bound.
const dup_max = 255;
const infinite: u32 = 0xffff_ffff;
/// CHR_MAX of regcustom.h.
const chr_max: u64 = 0x7fff_fffe;

const Op = enum(u8) { char, any, set, split, jump, assert, look, match };
const Assertion = enum(u8) { bol, eol, bos, eos, word_start, word_end, boundary, not_boundary };
const Look = enum(u8) { ahead, ahead_not, behind, behind_not };

/// One program step. Jumps are relative (`x`, `y`) so copying or shifting
/// a block keeps it valid. char: `arg` code point (`fold`: ASCII case
/// insensitive, arg lower case); set: `arg` set index; assert: an
/// Assertion; look: a Look over the sub-program after it, which ends with
/// its own `match`, continuing at `x`.
const Inst = struct { op: Op = .match, fold: bool = false, arg: u32 = 0, x: i32 = 0, y: i32 = 0 };

/// A bracket expression or class escape: an ASCII bitmap, `high` for every
/// non-ASCII character, then explicit non-ASCII ranges; `negated` last.
const Set = struct { ascii: [2]u64 = .{ 0, 0 }, high: bool = false, range_start: u32 = 0, range_count: u32 = 0, negated: bool = false };

const Class = enum { alnum, alpha, ascii, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit, word };
const class_names = [_][]const u8{ "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "xdigit", "word" };

fn isUpper(c: u32) bool {
    return c >= 'A' and c <= 'Z';
}
fn isLower(c: u32) bool {
    return c >= 'a' and c <= 'z';
}
fn isDigit(c: u32) bool {
    return c >= '0' and c <= '9';
}
fn isAlpha(c: u32) bool {
    return isUpper(c) or isLower(c);
}
fn isSpace(c: u32) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}
fn isGraph(c: u32) bool {
    return c > ' ' and c < 127;
}
fn isWord(c: u32) bool {
    return isAlpha(c) or isDigit(c) or c == '_';
}

/// pg_ascii_tolower for the C strategy.
fn fold(c: u32) u32 {
    return if (isUpper(c)) c + 32 else c;
}

/// Membership of an ASCII character (C ctype) in a class.
fn classHas(class: Class, c: u32) bool {
    return switch (class) {
        .alnum => isAlpha(c) or isDigit(c),
        .alpha => isAlpha(c),
        .ascii => true,
        .blank => c == ' ' or c == '\t',
        .cntrl => c < 32 or c == 127,
        .digit => isDigit(c),
        .graph => isGraph(c),
        .lower => isLower(c),
        .print => isGraph(c) or c == ' ',
        .punct => isGraph(c) and !isAlpha(c) and !isDigit(c),
        .space => isSpace(c),
        .upper => isUpper(c),
        .xdigit => isDigit(c) or (fold(c) >= 'a' and fold(c) <= 'f'),
        .word => isWord(c),
    };
}

/// One UTF-8 character at `at` (an invalid byte stands for itself).
pub fn decode(bytes: []const u8, at: usize) struct { cp: u32, len: usize } {
    const lead = bytes[at];
    if (lead < 0x80) return .{ .cp = lead, .len = 1 };
    const width: usize = if (lead >= 0xf0 and lead < 0xf8) 4 else if (lead >= 0xe0) 3 else if (lead >= 0xc0) 2 else 1;
    if (width == 1 or at + width > bytes.len) return .{ .cp = lead, .len = 1 };
    var cp: u32 = lead & (@as(u32, 0x7f) >> @intCast(width));
    for (bytes[at + 1 .. at + width]) |byte| {
        if (byte & 0xc0 != 0x80) return .{ .cp = lead, .len = 1 };
        cp = (cp << 6) | (byte & 0x3f);
    }
    return .{ .cp = cp, .len = width };
}

/// similar_to_escape (similar_escape_internal of PostgreSQL 18): the ARE
/// for a SIMILAR TO pattern. `escape` null is the default backslash; an
/// empty escape disables escaping; more than one character is 22025; a
/// third escape-double-quote is 2200C. `out` holds 3 * pattern.len + 23
/// bytes.
pub fn similarToRegex(pattern: []const u8, escape: ?[]const u8, out: []u8) Error![]const u8 {
    var esc: []const u8 = "\\";
    if (escape) |given| {
        esc = given;
        if (given.len > 1) {
            const first = decode(given, 0);
            if (first.len != given.len) return error.InvalidEscapeSequence;
        }
    }
    if (out.len < 3 * pattern.len + 23) return error.TextCapacity;
    var r: usize = 0;
    const put = struct {
        fn f(buffer: []u8, at: *usize, bytes: []const u8) void {
            @memcpy(buffer[at.*..][0..bytes.len], bytes);
            at.* += bytes.len;
        }
    }.f;
    put(out, &r, "^(?:");
    var after_escape = false;
    var quotes: usize = 0;
    var bracket_depth: usize = 0;
    var class_pos: usize = 0;
    var p: usize = 0;
    while (p < pattern.len) {
        const pchar = pattern[p];
        if (esc.len > 1) {
            const width = decode(pattern, p).len;
            if (width > 1) {
                if (after_escape) {
                    put(out, &r, "\\");
                    put(out, &r, pattern[p..][0..width]);
                    after_escape = false;
                } else if (esc.len == width and types.same(esc, pattern[p..][0..width])) {
                    after_escape = true;
                } else put(out, &r, pattern[p..][0..width]);
                p += width;
                continue;
            }
        }
        if (after_escape) {
            if (pchar == '"' and bracket_depth < 1) {
                if (quotes == 0) {
                    put(out, &r, "){1,1}?(");
                } else if (quotes == 1) {
                    put(out, &r, "){1,1}(?:");
                } else return error.InvalidEscapeCharacterUse;
                quotes += 1;
            } else {
                put(out, &r, &[_]u8{ '\\', pchar });
                class_pos = 3;
            }
            after_escape = false;
        } else if (esc.len != 0 and pchar == esc[0]) {
            after_escape = true;
        } else if (bracket_depth > 0) {
            if (pchar == '\\') put(out, &r, "\\");
            put(out, &r, &[_]u8{pchar});
            if (pchar == ']' and class_pos > 2) {
                bracket_depth -= 1;
            } else if (pchar == '[') {
                bracket_depth += 1;
                class_pos = 3;
            } else if (pchar == '^') {
                class_pos += 1;
            } else class_pos = 3;
        } else if (pchar == '[') {
            put(out, &r, "[");
            bracket_depth = 1;
            class_pos = 1;
        } else if (pchar == '%') {
            put(out, &r, ".*");
        } else if (pchar == '_') {
            put(out, &r, ".");
        } else if (pchar == '(') {
            put(out, &r, "(?:");
        } else if (pchar == '\\' or pchar == '.' or pchar == '^' or pchar == '$') {
            put(out, &r, &[_]u8{ '\\', pchar });
        } else put(out, &r, &[_]u8{pchar});
        p += 1;
    }
    put(out, &r, ")$");
    return out[0..r];
}

pub fn Regex(comptime states: usize) type {
    if (states < 8 or states > 30000) @compileError("Config.regex_states must be 8..30000");
    const set_capacity = states / 4 + 4;
    const range_capacity = states / 2 + 8;
    return struct {
        const Self = @This();
        insts: [states]Inst = undefined,
        len: usize = 0,
        sets: [set_capacity]Set = undefined,
        set_len: usize = 0,
        ranges: [range_capacity][2]u32 = undefined,
        range_len: usize = 0,
        flags: Flags = .{},

        // ---- compilation ----------------------------------------------

        const Compiler = struct {
            re: *Self,
            src: []const u8,
            at: usize = 0,
            flags: Flags,
            /// Capturing groups opened so far, and which of them are closed.
            groups: usize = 0,
            closed: [8]u64 = @splat(0),
            look_depth: usize = 0,
            depth_limit: usize,

            fn fail() Error {
                return error.InvalidRegularExpression;
            }

            fn more(self: *const Compiler) bool {
                return self.at < self.src.len;
            }

            fn peek(self: *const Compiler, offset: usize) ?u8 {
                return if (self.at + offset < self.src.len) self.src[self.at + offset] else null;
            }

            fn emit(self: *Compiler, inst: Inst) Error!usize {
                const re = self.re;
                if (re.len == states) return error.ProgramLimitExceeded;
                re.insts[re.len] = inst;
                re.len += 1;
                return re.len - 1;
            }

            /// Opens `count` instructions at `at`, shifting the rest.
            fn insert(self: *Compiler, at: usize, count: usize) Error!void {
                const re = self.re;
                if (states - re.len < count) return error.ProgramLimitExceeded;
                var index = re.len;
                while (index > at) : (index -= 1) re.insts[index - 1 + count] = re.insts[index - 1];
                re.len += count;
            }

            /// Expanded syntax white space and #-comments; ARE (?#...)
            /// comments are dropped wherever a token may start.
            fn skipIgnorable(self: *Compiler) void {
                while (self.more()) {
                    const byte = self.src[self.at];
                    if (self.flags.expanded and isSpace(byte)) {
                        self.at += 1;
                    } else if (self.flags.expanded and byte == '#') {
                        while (self.more() and self.src[self.at] != '\n') self.at += 1;
                    } else if (!self.flags.ere and byte == '(' and self.peek(1) == '?' and self.peek(2) == '#') {
                        self.at += 3;
                        while (self.more() and self.src[self.at] != ')') self.at += 1;
                        if (self.more()) self.at += 1;
                    } else return;
                }
            }

            fn literal(self: *Compiler, cp: u32) Error!void {
                if (self.flags.icase and isAlpha(cp)) {
                    _ = try self.emit(.{ .op = .char, .fold = true, .arg = fold(cp) });
                } else _ = try self.emit(.{ .op = .char, .arg = cp });
            }

            fn newSet(self: *Compiler) Error!*Set {
                const re = self.re;
                if (re.set_len == set_capacity) return error.ProgramLimitExceeded;
                re.sets[re.set_len] = .{ .range_start = @intCast(re.range_len) };
                re.set_len += 1;
                return &re.sets[re.set_len - 1];
            }

            fn addAscii(set: *Set, c: u32) void {
                set.ascii[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
            }

            /// Adds [low, high] (with ASCII case variants when insensitive).
            fn addRange(self: *Compiler, set: *Set, low: u32, high: u32) Error!void {
                var c = low;
                while (c <= high and c < 128) : (c += 1) {
                    addAscii(set, c);
                    if (self.flags.icase and isAlpha(c)) addAscii(set, if (isUpper(c)) c + 32 else c - 32);
                }
                if (high >= 128) {
                    const re = self.re;
                    // Ranges of a set are contiguous: only the newest set grows.
                    if (re.range_len == range_capacity) return error.ProgramLimitExceeded;
                    re.ranges[re.range_len] = .{ @max(low, 128), high };
                    re.range_len += 1;
                    set.range_count += 1;
                }
            }

            fn addClass(self: *Compiler, set: *Set, class_in: Class, complement: bool) Error!void {
                var class = class_in;
                if (self.flags.icase and (class == .lower or class == .upper)) class = .alpha;
                for (0..128) |c| {
                    if (classHas(class, @intCast(c)) != complement) addAscii(set, @intCast(c));
                }
                if (complement) {
                    set.high = true;
                } else if (class == .cntrl) try self.addRange(set, 0x80, 0x9f);
            }

            /// An escape's result: a character, a class (complemented or
            /// not), a constraint, or a back reference (`value` its number).
            const Escape = struct { kind: enum { char, class, complement, assert, backref }, value: u32 = 0, class: Class = .digit, assertion: Assertion = .bos };

            fn digits(self: *Compiler, base: u32, min: usize, max: usize) Error!u64 {
                var value: u64 = 0;
                var count: usize = 0;
                while (count < max and self.more()) {
                    const byte = self.src[self.at];
                    const digit: u32 = if (isDigit(byte)) byte - '0' else if (fold(byte) >= 'a' and fold(byte) <= 'f') fold(byte) - 'a' + 10 else 99;
                    if (digit >= base) break;
                    value = @min(value * base + digit, 0xffff_ffff_ffff);
                    self.at += 1;
                    count += 1;
                }
                if (count < min) return fail();
                return value;
            }

            /// lexescape: the backslash is consumed; `bracket` limits the
            /// result to characters and classes (REG_EESCAPE otherwise).
            fn escape(self: *Compiler, in_bracket: bool) Error!Escape {
                if (!self.more()) return fail();
                const lead = decode(self.src, self.at);
                const c = lead.cp;
                self.at += lead.len;
                if (self.flags.ere) return .{ .kind = .char, .value = c };
                if (!(isAlpha(c) or isDigit(c))) return .{ .kind = .char, .value = c };
                const out: Escape = switch (c) {
                    'a' => .{ .kind = .char, .value = 7 },
                    'A' => .{ .kind = .assert, .assertion = .bos },
                    'b' => .{ .kind = .char, .value = 8 },
                    'B' => .{ .kind = .char, .value = '\\' },
                    'c' => blk: {
                        if (!self.more()) return fail();
                        const next = decode(self.src, self.at);
                        self.at += next.len;
                        break :blk .{ .kind = .char, .value = next.cp & 0o37 };
                    },
                    'd' => .{ .kind = .class, .class = .digit },
                    'D' => .{ .kind = .complement, .class = .digit },
                    'e' => .{ .kind = .char, .value = 27 },
                    'f' => .{ .kind = .char, .value = 12 },
                    'm' => .{ .kind = .assert, .assertion = .word_start },
                    'M' => .{ .kind = .assert, .assertion = .word_end },
                    'n' => .{ .kind = .char, .value = '\n' },
                    'r' => .{ .kind = .char, .value = '\r' },
                    's' => .{ .kind = .class, .class = .space },
                    'S' => .{ .kind = .complement, .class = .space },
                    't' => .{ .kind = .char, .value = '\t' },
                    'u' => .{ .kind = .char, .value = @intCast(try self.digits(16, 4, 4)) },
                    'U' => blk: {
                        const value = try self.digits(16, 8, 8);
                        if (value > chr_max) return fail();
                        break :blk .{ .kind = .char, .value = @intCast(value) };
                    },
                    'v' => .{ .kind = .char, .value = 11 },
                    'w' => .{ .kind = .class, .class = .word },
                    'W' => .{ .kind = .complement, .class = .word },
                    'x' => blk: {
                        const value = try self.digits(16, 1, 255);
                        if (value > chr_max) return fail();
                        break :blk .{ .kind = .char, .value = @intCast(value) };
                    },
                    'y' => .{ .kind = .assert, .assertion = .boundary },
                    'Y' => .{ .kind = .assert, .assertion = .not_boundary },
                    'Z' => .{ .kind = .assert, .assertion = .eos },
                    '1'...'9' => blk: {
                        const save = self.at;
                        self.at -= 1;
                        const number = try self.digits(10, 1, 255);
                        // A single digit, or a number of an opened group.
                        if (self.at == save or (number > 0 and number <= self.groups)) break :blk .{ .kind = .backref, .value = @intCast(@min(number, 0xffff)) };
                        self.at = save;
                        break :blk try self.octal();
                    },
                    '0' => try self.octal(),
                    else => return fail(),
                };
                if (in_bracket and out.kind != .char and out.kind != .class and out.kind != .complement) return fail();
                return out;
            }

            /// An octal escape whose first digit is just before `at`.
            fn octal(self: *Compiler) Error!Escape {
                self.at -= 1;
                var value = try self.digits(8, 1, 3);
                if (value > 0xff) {
                    // One digit too many.
                    self.at -= 1;
                    value >>= 3;
                }
                return .{ .kind = .char, .value = @intCast(value) };
            }

            /// Text up to `close` (".]", "=]" or ":]") inside a bracket.
            fn bracketName(self: *Compiler, close: u8) Error![]const u8 {
                const start = self.at;
                while (true) {
                    if (!self.more()) return fail();
                    if (self.src[self.at] == close and self.peek(1) == ']') break;
                    self.at += decode(self.src, self.at).len;
                }
                const name = self.src[start..self.at];
                self.at += 2;
                return name;
            }

            /// element(): one character, or a POSIX collating-element name.
            fn element(name: []const u8) Error!u32 {
                if (name.len == 0) return fail();
                const first = decode(name, 0);
                if (first.len == name.len) return first.cp;
                for (collating_names, collating_codes) |candidate, code| if (types.same(candidate, name)) return code;
                return fail();
            }

            /// bracket(): after `[`.
            fn bracket(self: *Compiler) Error!void {
                const set = try self.newSet();
                const set_index = self.re.set_len - 1;
                if (self.more() and self.src[self.at] == '^') {
                    set.negated = true;
                    self.at += 1;
                }
                var first = true;
                while (true) {
                    if (!self.more()) return fail();
                    const byte = self.src[self.at];
                    if (byte == ']' and !first) {
                        self.at += 1;
                        break;
                    }
                    if (byte == '-' and !first and self.peek(1) != ']') return fail(); // a-b-c
                    first = false;
                    var start: u32 = 0;
                    var rangeable = true;
                    if (byte == '[' and (self.peek(1) == '.' or self.peek(1) == '=' or self.peek(1) == ':')) {
                        const kind = self.peek(1).?;
                        self.at += 2;
                        const name = try self.bracketName(kind);
                        switch (kind) {
                            '.' => start = try element(name),
                            '=' => {
                                // eclass: in C the character itself.
                                const c = try element(name);
                                try self.addRange(set, c, c);
                                continue;
                            },
                            else => {
                                if (name.len == 0) return fail();
                                const class = for (class_names, 0..) |candidate, index| {
                                    if (types.same(candidate, name)) break @as(Class, @enumFromInt(index));
                                } else return fail();
                                try self.addClass(set, class, false);
                                rangeable = false;
                            },
                        }
                    } else if (byte == '\\' and !self.flags.ere) {
                        self.at += 1;
                        const result = try self.escape(true);
                        switch (result.kind) {
                            .char => start = result.value,
                            .class, .complement => {
                                try self.addClass(set, result.class, result.kind == .complement);
                                rangeable = false;
                            },
                            else => return fail(),
                        }
                    } else {
                        const lead = decode(self.src, self.at);
                        self.at += lead.len;
                        start = lead.cp;
                    }
                    // A range: `-` not followed by the closing bracket.
                    const is_range = self.more() and self.src[self.at] == '-' and self.peek(1) != null and self.peek(1) != ']';
                    if (!rangeable) {
                        if (is_range) return fail();
                        continue;
                    }
                    var end = start;
                    if (is_range) {
                        self.at += 1;
                        const next = self.src[self.at];
                        if (next == '[' and self.peek(1) == '.') {
                            self.at += 2;
                            end = try element(try self.bracketName('.'));
                        } else if (next == '[' and (self.peek(1) == '=' or self.peek(1) == ':')) {
                            return fail();
                        } else if (next == '\\' and !self.flags.ere) {
                            self.at += 1;
                            const result = try self.escape(true);
                            if (result.kind != .char) return fail();
                            end = result.value;
                        } else {
                            const lead = decode(self.src, self.at);
                            self.at += lead.len;
                            end = lead.cp;
                        }
                        if (end < start) return fail();
                    }
                    try self.addRange(set, start, end);
                }
                // In NLSTOP mode a complemented bracket never matches newline.
                if (set.negated and self.flags.nlstop) addAscii(set, '\n');
                _ = try self.emit(.{ .op = .set, .arg = @intCast(set_index) });
            }

            fn classSet(self: *Compiler, class: Class, complement: bool) Error!void {
                const set = try self.newSet();
                const index = self.re.set_len - 1;
                try self.addClass(set, class, false);
                set.negated = complement;
                _ = try self.emit(.{ .op = .set, .arg = @intCast(index) });
            }

            const Item = enum { atom, constraint, none };

            /// parseqatom without the quantifier: one atom or constraint.
            fn atom(self: *Compiler, depth: usize) Error!Item {
                const byte = self.src[self.at];
                switch (byte) {
                    '(' => {
                        self.at += 1;
                        if (!self.flags.ere and self.more() and self.src[self.at] == '?') {
                            self.at += 1;
                            const kind = self.peek(0) orelse return fail();
                            self.at += 1;
                            switch (kind) {
                                ':' => {
                                    try self.alternation(true, depth + 1);
                                    return .atom;
                                },
                                '=', '!' => return self.lookaround(if (kind == '=') .ahead else .ahead_not, depth),
                                '<' => {
                                    const which = self.peek(0) orelse return fail();
                                    self.at += 1;
                                    if (which == '=') return self.lookaround(.behind, depth);
                                    if (which == '!') return self.lookaround(.behind_not, depth);
                                    return fail();
                                },
                                else => return fail(),
                            }
                        }
                        // Inside a lookaround every group is non-capturing.
                        var number: usize = 0;
                        if (self.look_depth == 0) {
                            self.groups += 1;
                            number = self.groups;
                        }
                        try self.alternation(true, depth + 1);
                        if (number != 0 and number < 512) self.closed[number >> 6] |= @as(u64, 1) << @intCast(number & 63);
                        return .atom;
                    },
                    ')' => return fail(),
                    '[' => {
                        // [[:<:]] and [[:>:]] are word constraints.
                        if (self.src.len - self.at >= 7 and self.src[self.at + 1] == '[' and self.src[self.at + 2] == ':' and
                            (self.src[self.at + 3] == '<' or self.src[self.at + 3] == '>') and self.src[self.at + 4] == ':' and
                            self.src[self.at + 5] == ']' and self.src[self.at + 6] == ']')
                        {
                            const start = self.src[self.at + 3] == '<';
                            self.at += 7;
                            _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(if (start) Assertion.word_start else Assertion.word_end) });
                            return .constraint;
                        }
                        self.at += 1;
                        try self.bracket();
                        return .atom;
                    },
                    '.' => {
                        self.at += 1;
                        _ = try self.emit(.{ .op = .any });
                        return .atom;
                    },
                    '^', '$' => {
                        self.at += 1;
                        _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(if (byte == '^') Assertion.bol else Assertion.eol) });
                        return .constraint;
                    },
                    '*', '+', '?' => return fail(),
                    '{' => {
                        // A bound without an operand; `{` before a non-digit is literal.
                        var probe = self.at + 1;
                        if (self.flags.expanded) {
                            while (probe < self.src.len and isSpace(self.src[probe])) probe += 1;
                        }
                        if (probe < self.src.len and isDigit(self.src[probe])) return fail();
                        self.at += 1;
                        try self.literal('{');
                        return .atom;
                    },
                    '\\' => {
                        self.at += 1;
                        const result = try self.escape(false);
                        switch (result.kind) {
                            .char => try self.literal(result.value),
                            .class, .complement => try self.classSet(result.class, result.kind == .complement),
                            .assert => {
                                _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(result.assertion) });
                                return .constraint;
                            },
                            .backref => {
                                // Valid only for a closed group outside lookarounds.
                                const number = result.value;
                                if (self.look_depth != 0 or number >= 512 or self.closed[number >> 6] & (@as(u64, 1) << @intCast(number & 63)) == 0) return fail();
                                return error.UnsupportedStatement;
                            },
                        }
                        return .atom;
                    },
                    else => {
                        const lead = decode(self.src, self.at);
                        self.at += lead.len;
                        try self.literal(lead.cp);
                        return .atom;
                    },
                }
            }

            fn lookaround(self: *Compiler, kind: Look, depth: usize) Error!Item {
                if (self.look_depth == max_look_depth) return error.UnsupportedStatement;
                const look = try self.emit(.{ .op = .look, .arg = @intFromEnum(kind) });
                self.look_depth += 1;
                try self.alternation(true, depth + 1);
                self.look_depth -= 1;
                _ = try self.emit(.{ .op = .match });
                self.re.insts[look].x = @intCast(self.re.len - look);
                return .constraint;
            }

            /// A bound number (scannum): at most 255.
            fn boundNumber(self: *Compiler) Error!u32 {
                var value: u32 = 0;
                var count: usize = 0;
                while (self.more() and isDigit(self.src[self.at])) : (count += 1) {
                    value = value * 10 + (self.src[self.at] - '0');
                    if (value > dup_max) return fail();
                    self.at += 1;
                }
                if (count == 0) return fail();
                return value;
            }

            fn skipBoundSpace(self: *Compiler) void {
                if (self.flags.expanded) self.skipIgnorable();
            }

            /// The quantifier after an atom at [start, len), if any.
            fn quantifier(self: *Compiler, start: usize) Error!void {
                self.skipIgnorable();
                if (!self.more()) return;
                var low: u32 = 1;
                var high: u32 = 1;
                switch (self.src[self.at]) {
                    '*', '+', '?' => |byte| {
                        self.at += 1;
                        low = if (byte == '+') 1 else 0;
                        high = if (byte == '?') 1 else infinite;
                        if (!self.flags.ere and self.more() and self.src[self.at] == '?') self.at += 1;
                    },
                    '{' => {
                        var probe = self.at + 1;
                        if (self.flags.expanded) {
                            while (probe < self.src.len and isSpace(self.src[probe])) probe += 1;
                        }
                        if (probe >= self.src.len or !isDigit(self.src[probe])) return;
                        self.at += 1;
                        self.skipBoundSpace();
                        low = try self.boundNumber();
                        high = low;
                        self.skipBoundSpace();
                        if (self.more() and self.src[self.at] == ',') {
                            self.at += 1;
                            self.skipBoundSpace();
                            high = if (self.more() and isDigit(self.src[self.at])) try self.boundNumber() else infinite;
                            self.skipBoundSpace();
                            if (low > high) return fail();
                        }
                        if (!self.more() or self.src[self.at] != '}') return fail();
                        self.at += 1;
                        if (!self.flags.ere and self.more() and self.src[self.at] == '?') self.at += 1;
                    },
                    else => return,
                }
                try self.repeat(start, low, high);
            }

            /// Repeats the block [start, len) between `low` and `high` times.
            fn repeat(self: *Compiler, start: usize, low: u32, high: u32) Error!void {
                const re = self.re;
                const body = re.len - start;
                if (low == 1 and high == 1) return;
                if (high == 0) {
                    // {0} and {0,0} drop the atom (its groups still count).
                    re.len = start;
                    return;
                }
                if (high == infinite) {
                    if (low == 0) {
                        // split(body, out); body; jump split
                        try self.insert(start, 1);
                        re.insts[start] = .{ .op = .split, .x = 1, .y = @intCast(body + 2) };
                        const back = try self.emit(.{ .op = .jump });
                        re.insts[back].x = -@as(i32, @intCast(back - start));
                        return;
                    }
                    // body^(low - 1), then body+.
                    if ((states - re.len) / @max(body, 1) < low - 1) return error.ProgramLimitExceeded;
                    for (1..low) |_| try self.copy(start, body);
                    const last = re.len - body;
                    const loop = try self.emit(.{ .op = .split, .y = 1 });
                    re.insts[loop].x = -@as(i32, @intCast(loop - last));
                    return;
                }
                // body^low, then (high - low) optional copies skipping to the end.
                const optional = high - low;
                const needed = @as(u64, body) * high + optional;
                if (needed > states - start) return error.ProgramLimitExceeded;
                var splits: [dup_max + 1]usize = undefined;
                var count: usize = 0;
                if (low == 0) {
                    try self.insert(start, 1);
                    re.insts[start] = .{ .op = .split, .x = 1 };
                    splits[count] = start;
                    count += 1;
                }
                const body_start = if (low == 0) start + 1 else start;
                for (1..high) |index| {
                    if (index >= low) {
                        splits[count] = try self.emit(.{ .op = .split, .x = 1 });
                        count += 1;
                    }
                    try self.copy(body_start, body);
                }
                for (splits[0..count]) |split| re.insts[split].y = @intCast(re.len - split);
            }

            fn copy(self: *Compiler, from: usize, count: usize) Error!void {
                const re = self.re;
                if (states - re.len < count) return error.ProgramLimitExceeded;
                for (0..count) |index| re.insts[re.len + index] = re.insts[from + index];
                re.len += count;
            }

            fn branch(self: *Compiler, depth: usize) Error!void {
                while (true) {
                    self.skipIgnorable();
                    if (!self.more()) return;
                    const byte = self.src[self.at];
                    if (byte == '|' or byte == ')') return;
                    const start = self.re.len;
                    switch (try self.atom(depth)) {
                        .atom => try self.quantifier(start),
                        .constraint, .none => {},
                    }
                }
            }

            /// Branches separated by `|`, up to `)` (`group`) or the end.
            fn alternation(self: *Compiler, group: bool, depth: usize) Error!void {
                if (depth > self.depth_limit) return error.StatementTooComplex;
                const re = self.re;
                var placeholder = try self.emit(.{ .op = .jump, .x = 1 });
                // Pending end jumps, linked through `arg` (index + 1).
                var pending: u32 = 0;
                try self.branch(depth);
                while (self.more() and self.src[self.at] == '|') {
                    self.at += 1;
                    const jump = try self.emit(.{ .op = .jump, .arg = pending });
                    pending = @intCast(jump + 1);
                    re.insts[placeholder] = .{ .op = .split, .x = 1, .y = @intCast(re.len - placeholder) };
                    placeholder = try self.emit(.{ .op = .jump, .x = 1 });
                    try self.branch(depth);
                }
                while (pending != 0) {
                    const jump = pending - 1;
                    pending = re.insts[jump].arg;
                    re.insts[jump].arg = 0;
                    re.insts[jump].x = @intCast(re.len - jump);
                }
                if (group) {
                    if (!self.more() or self.src[self.at] != ')') return fail();
                    self.at += 1;
                } else if (self.more()) return fail();
            }

            /// prefixes(): `***:`, `***=` and the leading embedded options.
            fn prefixes(self: *Compiler) Error!void {
                if (self.flags.quote) return;
                if (self.src.len >= 4 and self.src[0] == '*' and self.src[1] == '*' and self.src[2] == '*') {
                    switch (self.src[3]) {
                        '=' => {
                            self.flags.quote = true;
                            self.flags.expanded = false;
                            self.flags.nlstop = false;
                            self.flags.nlanch = false;
                            self.at = 4;
                            return;
                        },
                        ':' => {
                            self.flags.ere = false;
                            self.at = 4;
                        },
                        else => return fail(),
                    }
                }
                if (self.flags.ere) return;
                if (self.src.len - self.at >= 3 and self.src[self.at] == '(' and self.src[self.at + 1] == '?' and isAlpha(self.src[self.at + 2])) {
                    self.at += 2;
                    while (self.more() and isAlpha(self.src[self.at])) : (self.at += 1) switch (self.src[self.at]) {
                        'b' => return error.UnsupportedStatement,
                        'c' => self.flags.icase = false,
                        'e' => {
                            self.flags.ere = true;
                            self.flags.quote = false;
                        },
                        'i' => self.flags.icase = true,
                        'm', 'n' => {
                            self.flags.nlstop = true;
                            self.flags.nlanch = true;
                        },
                        'p' => {
                            self.flags.nlstop = true;
                            self.flags.nlanch = false;
                        },
                        'q' => self.flags.quote = true,
                        's' => {
                            self.flags.nlstop = false;
                            self.flags.nlanch = false;
                        },
                        't' => self.flags.expanded = false,
                        'w' => {
                            self.flags.nlstop = false;
                            self.flags.nlanch = true;
                        },
                        'x' => self.flags.expanded = true,
                        else => return fail(),
                    };
                    if (!self.more() or self.src[self.at] != ')') return fail();
                    self.at += 1;
                    if (self.flags.quote) {
                        self.flags.expanded = false;
                        self.flags.nlstop = false;
                        self.flags.nlanch = false;
                    }
                }
            }
        };

        /// Compiles `pattern` (2201B when malformed). `depth_limit` bounds
        /// group nesting (54001 beyond).
        pub fn compile(self: *Self, pattern: []const u8, flags: Flags, depth_limit: usize) Error!void {
            self.len = 0;
            self.set_len = 0;
            self.range_len = 0;
            var compiler: Compiler = .{ .re = self, .src = pattern, .flags = flags, .depth_limit = depth_limit };
            try compiler.prefixes();
            self.flags = compiler.flags;
            if (compiler.flags.quote) {
                // A literal string.
                while (compiler.more()) {
                    const lead = decode(pattern, compiler.at);
                    compiler.at += lead.len;
                    try compiler.literal(lead.cp);
                }
            } else try compiler.alternation(false, 0);
            _ = try compiler.emit(.{ .op = .match });
        }

        // ---- matching ---------------------------------------------------

        const List = struct {
            dense: [states]u16 = undefined,
            sparse: [states]u16 = undefined,
            len: usize = 0,

            fn has(self: *const List, pc: usize) bool {
                const slot = self.sparse[pc];
                return slot < self.len and self.dense[slot] == pc;
            }

            fn add(self: *List, pc: usize) void {
                self.sparse[pc] = @intCast(self.len);
                self.dense[self.len] = @intCast(pc);
                self.len += 1;
            }
        };

        fn inSet(self: *const Self, index: u32, cp: u32) bool {
            const set = &self.sets[index];
            var hit = false;
            if (cp < 128) {
                hit = set.ascii[cp >> 6] & (@as(u64, 1) << @intCast(cp & 63)) != 0;
            } else if (set.high) {
                hit = true;
            } else for (self.ranges[set.range_start..][0..set.range_count]) |range| {
                if (cp >= range[0] and cp <= range[1]) {
                    hit = true;
                    break;
                }
            }
            return hit != set.negated;
        }

        /// The character before byte offset `at` (null at the start).
        fn before(text: []const u8, at: usize) ?u32 {
            if (at == 0) return null;
            var start = at - 1;
            while (start > 0 and at - start < 4 and text[start] & 0xc0 == 0x80) start -= 1;
            const found = decode(text, start);
            if (start + found.len == at) return found.cp;
            return text[at - 1];
        }

        fn wordAt(cp: ?u32) bool {
            return if (cp) |c| isWord(c) else false;
        }

        fn holds(self: *const Self, assertion: Assertion, text: []const u8, at: usize) bool {
            const prev = before(text, at);
            const next: ?u32 = if (at < text.len) decode(text, at).cp else null;
            return switch (assertion) {
                .bol => at == 0 or (self.flags.nlanch and prev == '\n'),
                .eol => at == text.len or (self.flags.nlanch and next == '\n'),
                .bos => at == 0,
                .eos => at == text.len,
                .word_start => !wordAt(prev) and wordAt(next),
                .word_end => wordAt(prev) and !wordAt(next),
                .boundary => wordAt(prev) != wordAt(next),
                .not_boundary => wordAt(prev) == wordAt(next),
            };
        }

        /// Epsilon closure of `pc` at byte offset `at` into `list`.
        fn addThread(self: *const Self, comptime level: usize, list: *List, stack: *[2 * states + 2]u16, pc0: usize, text: []const u8, at: usize, control: ?*types.ExecutionControl) Error!void {
            var top: usize = 0;
            stack[top] = @intCast(pc0);
            top += 1;
            while (top != 0) {
                top -= 1;
                const pc: usize = stack[top];
                if (list.has(pc)) continue;
                list.add(pc);
                const inst = self.insts[pc];
                switch (inst.op) {
                    .jump => {
                        stack[top] = @intCast(@as(i64, @intCast(pc)) + inst.x);
                        top += 1;
                    },
                    .split => {
                        stack[top] = @intCast(@as(i64, @intCast(pc)) + inst.y);
                        stack[top + 1] = @intCast(@as(i64, @intCast(pc)) + inst.x);
                        top += 2;
                    },
                    .assert => if (self.holds(@enumFromInt(inst.arg), text, at)) {
                        stack[top] = @intCast(pc + 1);
                        top += 1;
                    },
                    .look => if (comptime level >= max_look_depth) {
                        // compile() never nests lookarounds this deep.
                        return error.UnsupportedStatement;
                    } else {
                        const kind: Look = @enumFromInt(inst.arg);
                        const found = switch (kind) {
                            .ahead, .ahead_not => try self.run(level + 1, pc + 1, text, at, null, control),
                            .behind, .behind_not => try self.run(level + 1, pc + 1, text, 0, at, control),
                        };
                        const wanted = kind == .ahead or kind == .behind;
                        if (found == wanted) {
                            stack[top] = @intCast(@as(i64, @intCast(pc)) + inst.x);
                            top += 1;
                        }
                    },
                    .char, .any, .set, .match => {},
                }
            }
        }

        fn consumes(self: *const Self, inst: Inst, cp: u32) bool {
            return switch (inst.op) {
                .char => (if (inst.fold) fold(cp) else cp) == inst.arg,
                .any => !(self.flags.nlstop and cp == '\n'),
                .set => self.inSet(inst.arg, cp),
                else => false,
            };
        }

        /// Simulates the program from `entry`. Without `end`: is there a
        /// match starting at `from` (level 0: at any position from `from`
        /// on); with `end`: does some match starting at or after `from` end
        /// exactly at byte offset `end` (lookbehind).
        fn run(self: *const Self, comptime level: usize, entry: usize, text: []const u8, from: usize, end: ?usize, control: ?*types.ExecutionControl) Error!bool {
            var lists: [2]List = .{ .{}, .{} };
            var stack: [2 * states + 2]u16 = undefined;
            var current: usize = 0;
            var at = from;
            const unanchored = level == 0 or end != null;
            while (true) {
                if (control) |active| try active.checkpoint();
                const list = &lists[current];
                if (unanchored or at == from) try self.addThread(level, list, &stack, entry, text, at, control);
                if (end) |stop| {
                    if (at == stop) {
                        for (list.dense[0..list.len]) |pc| if (self.insts[pc].op == .match) return true;
                        return false;
                    }
                } else for (list.dense[0..list.len]) |pc| if (self.insts[pc].op == .match) return true;
                if (at >= text.len) return false;
                if (list.len == 0 and !unanchored) return false;
                const step = decode(text, at);
                const next = &lists[1 - current];
                next.len = 0;
                for (list.dense[0..list.len]) |pc| {
                    const inst = self.insts[pc];
                    if (self.consumes(inst, step.cp)) try self.addThread(level, next, &stack, pc + 1, text, at + step.len, control);
                }
                list.len = 0;
                current = 1 - current;
                at += step.len;
            }
        }

        /// Whether the compiled expression matches somewhere in `text`.
        pub fn search(self: *const Self, text: []const u8, control: ?*types.ExecutionControl) Error!bool {
            return self.run(0, 0, text, 0, null, control);
        }
    };
}

/// POSIX collating-element names (regc_locale.c cnames) and their codes.
const collating_names = [_][]const u8{
    "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "alert", "BS", "backspace", "HT",
    "tab", "LF", "newline", "VT", "vertical-tab", "FF", "form-feed", "CR", "carriage-return", "SO",
    "SI", "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM", "SUB", "ESC", "IS4",
    "FS", "IS3", "GS", "IS2", "RS", "IS1", "US", "space", "exclamation-mark", "quotation-mark",
    "number-sign", "dollar-sign", "percent-sign", "ampersand", "apostrophe", "left-parenthesis",
    "right-parenthesis", "asterisk", "plus-sign", "comma", "hyphen", "hyphen-minus", "period",
    "full-stop", "slash", "solidus", "zero", "one", "two", "three", "four", "five", "six", "seven",
    "eight", "nine", "colon", "semicolon", "less-than-sign", "equals-sign", "greater-than-sign",
    "question-mark", "commercial-at", "left-square-bracket", "backslash", "reverse-solidus",
    "right-square-bracket", "circumflex", "circumflex-accent", "underscore", "low-line",
    "grave-accent", "left-brace", "left-curly-bracket", "vertical-line", "right-brace",
    "right-curly-bracket", "tilde", "DEL",
};
const collating_codes = [_]u8{
    0, 1, 2, 3, 4, 5, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 28, 29, 29, 30, 30, 31, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 45, 46, 46, 47, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
    61, 62, 63, 64, 91, 92, 92, 93, 94, 94, 95, 95, 96, 123, 123, 124, 125, 125, 126, 127,
};
