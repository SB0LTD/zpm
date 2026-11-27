//! POSIX regular expressions (Layer 0), conformance lane B11 "text" and
//! wave 4 "text-json": PostgreSQL's regular expressions (regcomp.c,
//! regc_lex.c, regexec.c) for `~ ~* !~ !~*`, SIMILAR TO, substring and the
//! regexp_* functions.
//!
//! Patterns compile into a bounded Thompson-NFA program (at most `states`
//! instructions, Config.regex_states) plus PostgreSQL's subexpression tree
//! (parse/parsebranch/parseqatom of regcomp.c): plain nodes, concatenation,
//! alternation, iteration, capture and back reference nodes, each owning a
//! contiguous block of the program. Matching is Pike-VM simulation over a
//! block: the leftmost start, then the longest or shortest end by the
//! whole expression's preference (find), and capture positions by
//! regexec.c's dissection (ccondissect, crevcondissect, caltdissect,
//! citerdissect, creviterdissect, cbrdissect) with each node's own
//! greediness. Expressions with back references run cfind: every
//! candidate end of the leftmost possible start is dissected until one
//! verifies. Every text position simulated is one ExecutionControl
//! checkpoint, also inside lookarounds and dissection; nothing allocates.
//!
//! Syntax: AREs, EREs (`(?e)`) and BREs (`(?b)`; regexp options `b` and
//! `e`), literal strings (`***=`, `(?q)`, option `q`): every escape (\a \b
//! \B \cX \e \f \n \r \t \uXXXX \UXXXXXXXX \v \xHH... octal \0, \NN, \NNN),
//! back references \N (ARE) and \1-\9 (BRE), `.`, bracket expressions
//! with ranges, [:class:], [.element.] (single characters and the POSIX
//! names) and [=x=], \d \s \w \D \S \W (also inside brackets), groups,
//! alternation, `* + ? {m} {m,} {m,n}` and their non-greedy forms (bounds
//! up to 255), constraints `^ $ \A \Z \m \M \y \Y [[:<:]] [[:>:]]`,
//! lookahead and lookbehind `(?= (?! (?<= (?<!` nested as deep as group
//! nesting allows, comments `(?#...)`, directors `***:` and `***=` and the
//! leading embedded options `(?bcefimnpqstwx)`. Group and lookaround
//! nesting beyond the caller's depth limit (Config.expr_depth) is 54001.
//!
//! Character semantics are the libc wide-character strategy of
//! regc_pg_locale.c (PG_REGEX_STRATEGY_LIBC_WIDE) for the C.UTF-8 ctype,
//! the one upper/lower use (unicode_case.sig): ASCII keeps the C
//! behaviour; non-ASCII characters belong to classes per iswalpha,
//! iswupper, ... of C.UTF-8 (digit, xdigit, blank and ascii are ASCII
//! only; cntrl is 0-0x1f and 0x7f-0x9f); a case-insensitive character
//! stands for allcases(): towlower and towupper of it (not the character
//! itself), in brackets too, and a bracket range adds the case variants
//! of its members; back references compare towlower of each character.
//! Malformed patterns are 2201B (InvalidRegularExpression);
//! a program beyond `states` instructions, a subexpression tree beyond its
//! node capacity, more than `states` groups or iteration end points beyond
//! the caller's workspace are 54000.
const types = @import("types.sig");
const unicode_case = @import("unicode_case.sig");
const Error = types.Error;

/// Compilation flags: regcomp's cflags. `ere` clears REG_ADVF (no ARE
/// extensions) and `bre` clears REG_EXTENDED as well (basic syntax).
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
    /// No ARE escapes, extensions or embedded options (EREs and BREs).
    ere: bool = false,
    /// Basic regular expressions.
    bre: bool = false,
};

/// parse_re_flags: the option letters of the regexp functions over `base`.
/// `g` is reported for the caller; any other unknown letter is 22023. `b`
/// selects BREs, and so does `e`: parse_re_flags sets REG_EXTENDED and then
/// clears REG_ADVANCED, which includes it. `q` makes the pattern literal.
pub fn parseOptions(options: []const u8, base: Flags) Error!struct { flags: Flags, global: bool } {
    var flags = base;
    var global = false;
    for (options) |option| switch (option) {
        'g' => global = true,
        'b', 'e' => {
            flags.bre = true;
            flags.ere = true;
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
            flags.bre = true;
            flags.ere = true;
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
    return .{ .flags = flags, .global = global };
}

/// RE_DUP_MAX: the largest bound.
const dup_max = 255;
const infinite: u32 = 0xffff_ffff;
/// CHR_MAX of regcustom.h.
const chr_max: u64 = 0x7fff_fffe;

const Op = enum(u8) { char, any, set, split, jump, assert, look, match, fail };
const Assertion = enum(u8) { bol, eol, bos, eos, word_start, word_end, boundary, not_boundary };
const Look = enum(u8) { ahead, ahead_not, behind, behind_not };

/// One program step. Jumps are relative (`x`, `y`) so copying or shifting
/// a block keeps it valid. char: `arg` code point (`fold`: either `arg`
/// or the code point `x`, allcases()); set: `arg` set index; assert: an
/// Assertion; look: a Look over the sub-program after it, which ends with
/// its own `match`, continuing at `x`; fail: never matches (a back
/// reference to a group removed by `{0}`).
const Inst = struct { op: Op = .match, fold: bool = false, arg: u32 = 0, x: i32 = 0, y: i32 = 0 };

/// A bracket expression or class escape: an ASCII bitmap; for non-ASCII
/// characters the classes they may belong to (`classes`, one bit per
/// Class) or fall outside of (`not_classes`, \W and the like) and explicit
/// ranges; `negated` last.
const Set = struct { ascii: [2]u64 = .{ 0, 0 }, classes: u16 = 0, not_classes: u16 = 0, range_start: u32 = 0, range_count: u32 = 0, negated: bool = false };

// ---- subexpression tree (regguts.h subre) --------------------------------

/// Subexpression flags: LONGER, SHORTER, MIXED, CAP and BACKR.
const longer: u8 = 1;
const shorter: u8 = 2;
const mixed: u8 = 4;
const cap: u8 = 8;
const backr: u8 = 16;

/// UP(): the flags that propagate upwards; LONGER with SHORTER is MIXED.
fn up(f: u8) u8 {
    var result = f & (mixed | cap | backr);
    if (f & longer != 0 and f & shorter != 0) result |= mixed;
    return result;
}

fn isMessy(f: u8) bool {
    return f & (mixed | cap | backr) != 0;
}

fn prefOf(f: u8) u8 {
    return f & (longer | shorter);
}

/// COMBINE(): propagated flags plus the first preference.
fn combine(f1: u8, f2: u8) u8 {
    return up(f1 | f2) | (if (prefOf(f1) != 0) prefOf(f1) else prefOf(f2));
}

/// No node.
pub const no_sub: u16 = 0xffff;
/// A group removed by `{0}` (group_nodes marker).
const dropped_sub: u16 = 0xfffe;
/// An unbounded iteration or back-reference repetition.
const sub_infinite: u16 = 0xffff;

/// plain ('='), concat ('.'), alt ('|'), iter ('*'), capture ('(') and
/// backref ('b').
const SubOp = enum(u8) { plain, concat, alt, iter, capture, backref };

/// One subre: its program block is [begin, end) (a thread reaching `end`
/// has matched it); children are linked through `child` and `sibling`.
const Sub = struct {
    op: SubOp = .plain,
    flags: u8 = 0,
    /// A segment prefix with nothing before the messy atom.
    vacuous: bool = false,
    capno: u16 = 0,
    backno: u16 = 0,
    min: u16 = 1,
    max: u16 = 1,
    begin: u16 = 0,
    end: u16 = 0,
    child: u16 = no_sub,
    sibling: u16 = no_sub,
};

/// A match position pair in bytes; -1 when the group did not participate.
pub const Capture = struct { start: i32 = -1, end: i32 = -1 };

/// The text and storage of one match: `caps` (the whole match, then group
/// n at n; at least groups + 1 entries for patterns with back
/// references) and `work`, the iteration end points of dissection.
pub const Exec = struct {
    text: []const u8,
    caps: []Capture,
    work: []u32,
    used: usize = 0,
    control: ?*types.ExecutionControl = null,
};

fn nextChar(text: []const u8, at: usize) usize {
    return at + decode(text, at).len;
}

/// The start of the character before byte offset `at` (> 0).
fn prevChar(text: []const u8, at: usize) usize {
    var start = at - 1;
    while (start > 0 and at - start < 4 and text[start] & 0xc0 == 0x80) start -= 1;
    if (start + decode(text, start).len == at) return start;
    return at - 1;
}

/// Characters in text[from..to).
pub fn charCount(text: []const u8, from: usize, to: usize) usize {
    var count: usize = 0;
    var at = from;
    while (at < to) : (count += 1) at = nextChar(text, at);
    return count;
}

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

/// Membership of a non-ASCII character in a class (C.UTF-8).
fn highClassHas(class: Class, c: u32) bool {
    return switch (class) {
        .alnum, .alpha, .word => unicode_case.isAlnum(c),
        .upper => unicode_case.highUpper(c),
        .lower => unicode_case.highLower(c),
        .space => unicode_case.highSpace(c),
        .punct => unicode_case.highPunct(c),
        .print => unicode_case.highPrint(c),
        .graph => unicode_case.highGraph(c),
        .cntrl => c <= 0x9f,
        .ascii, .blank, .digit, .xdigit => false,
    };
}

/// A word character of \m \M \y \Y (alnum or `_`).
fn wordChar(c: u32) bool {
    return if (c < 128) isWord(c) else unicode_case.isAlnum(c);
}

/// The byte length of an expanded-syntax white space character at `at`
/// (iscspace), 0 when there is none.
fn spaceAt(src: []const u8, at: usize) usize {
    const ch = decode(src, at);
    if (ch.cp < 128) return if (isSpace(ch.cp)) 1 else 0;
    return if (unicode_case.highSpace(ch.cp)) ch.len else 0;
}

/// ASCII lower case (hexadecimal digits).
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
    const sub_capacity = states + states / 2 + 16;
    return struct {
        const Self = @This();
        /// Capturing groups one expression may open.
        pub const group_capacity = states;
        insts: [states]Inst = undefined,
        len: usize = 0,
        sets: [set_capacity]Set = undefined,
        set_len: usize = 0,
        ranges: [range_capacity][2]u32 = undefined,
        range_len: usize = 0,
        flags: Flags = .{},
        subs: [sub_capacity]Sub = undefined,
        sub_len: usize = 0,
        root: u16 = no_sub,
        /// Capturing groups (re_nsub).
        groups: usize = 0,
        has_backref: bool = false,

        // ---- compilation ----------------------------------------------

        const AtomKind = enum { constraint, plain, capture, backref };
        const Atom = struct { kind: AtomKind, node: u16 = no_sub };
        /// A quantifier: bounds and its preference (LONGER, SHORTER or 0).
        const Quant = struct { m: u32 = 1, n: u32 = 1, prefer: u8 = 0 };
        /// The previous BRE token class (LASTTYPE in brenext).
        const BreLast = enum { empty, open, caret, other };

        const Compiler = struct {
            re: *Self,
            src: []const u8,
            at: usize = 0,
            flags: Flags,
            /// Capturing groups opened so far.
            groups: usize = 0,
            /// The subre of each closed group (no_sub while open,
            /// dropped_sub when `{0}` removed it).
            group_nodes: [states + 1]u16 = undefined,
            look_depth: usize = 0,
            open_groups: usize = 0,
            bre_last: BreLast = .empty,
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

            /// Opens `count` instructions at `at`, shifting the rest and
            /// the subres created since `mark` (all inside the block).
            fn insert(self: *Compiler, at: usize, count: usize, mark: usize) Error!void {
                const re = self.re;
                if (states - re.len < count) return error.ProgramLimitExceeded;
                var index = re.len;
                while (index > at) : (index -= 1) re.insts[index - 1 + count] = re.insts[index - 1];
                re.len += count;
                self.shiftSubs(mark, count);
            }

            fn shiftSubs(self: *Compiler, mark: usize, delta: usize) void {
                const re = self.re;
                for (re.subs[mark..re.sub_len]) |*sub| {
                    sub.begin += @intCast(delta);
                    sub.end += @intCast(delta);
                }
            }

            fn newSub(self: *Compiler, sub: Sub) Error!u16 {
                const re = self.re;
                if (re.sub_len == sub_capacity) return error.ProgramLimitExceeded;
                re.subs[re.sub_len] = sub;
                re.sub_len += 1;
                return @intCast(re.sub_len - 1);
            }

            /// Forgets the subres created since `mark`; groups among them
            /// can no longer be referenced by a back reference.
            fn dropSubs(self: *Compiler, mark: usize) void {
                for (self.group_nodes[1 .. self.groups + 1]) |*entry| {
                    if (entry.* != no_sub and entry.* != dropped_sub and entry.* >= mark) entry.* = dropped_sub;
                }
                self.re.sub_len = mark;
            }

            fn reverse(self: *Compiler, from: usize, to: usize) void {
                var low = from;
                var high = to;
                while (low + 1 < high) {
                    high -= 1;
                    const keep = self.re.insts[low];
                    self.re.insts[low] = self.re.insts[high];
                    self.re.insts[high] = keep;
                    low += 1;
                }
            }

            /// Swaps the blocks [from, mid) and [mid, to); both are self
            /// contained (relative jumps), so each stays valid.
            fn rotate(self: *Compiler, from: usize, mid: usize, to: usize) void {
                self.reverse(from, mid);
                self.reverse(mid, to);
                self.reverse(from, to);
            }

            /// Expanded syntax white space and #-comments; ARE (?#...)
            /// comments are dropped wherever a token may start.
            fn skipIgnorable(self: *Compiler) void {
                while (self.more()) {
                    const byte = self.src[self.at];
                    if (self.flags.expanded and spaceAt(self.src, self.at) != 0) {
                        self.at += spaceAt(self.src, self.at);
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
                if (!self.flags.icase) {
                    _ = try self.emit(.{ .op = .char, .arg = cp });
                    return;
                }
                // allcases(): towlower and towupper, not cp itself.
                const lower = unicode_case.toLower(cp);
                const upper = unicode_case.toUpper(cp);
                if (lower == upper) {
                    _ = try self.emit(.{ .op = .char, .arg = lower });
                } else _ = try self.emit(.{ .op = .char, .fold = true, .arg = lower, .x = @intCast(upper) });
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

            /// range(): [low, high] and, when insensitive, the case variants
            /// of its members that fall outside it.
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
                    if (self.flags.icase) {
                        try self.addCaseRuns(set, &unicode_case.lower_runs, low, high);
                        try self.addCaseRuns(set, &unicode_case.upper_runs, low, high);
                    }
                }
            }

            /// The mappings of `runs` for members of [low, high] (non-ASCII
            /// ones; ASCII maps within ASCII) that leave the range.
            fn addCaseRuns(self: *Compiler, set: *Set, runs: []const unicode_case.Run, low: u32, high: u32) Error!void {
                const from = @max(low, 128);
                for (runs) |run| {
                    if (run.end < from or run.start > high) continue;
                    var c = run.start;
                    if (c < from) c += (from - c + run.stride - 1) / run.stride * run.stride;
                    while (c <= run.end and c <= high) : (c += run.stride) {
                        const target: u32 = @intCast(@as(i64, c) + run.delta);
                        if (target < low or target > high) try self.addChar(set, target);
                    }
                }
            }

            /// allcases(): towlower and towupper of `c`.
            fn addCases(self: *Compiler, set: *Set, c: u32) Error!void {
                const lower = unicode_case.toLower(c);
                const upper = unicode_case.toUpper(c);
                try self.addChar(set, lower);
                if (upper != lower) try self.addChar(set, upper);
            }

            /// One character, merged into the newest set's ranges.
            fn addChar(self: *Compiler, set: *Set, c: u32) Error!void {
                if (c < 128) {
                    addAscii(set, c);
                    return;
                }
                const re = self.re;
                for (re.ranges[set.range_start..][0..set.range_count]) |*range| {
                    if (c >= range[0] and c <= range[1]) return;
                    if (c == range[1] + 1) {
                        range[1] = c;
                        return;
                    }
                    if (c + 1 == range[0]) {
                        range[0] = c;
                        return;
                    }
                }
                if (re.range_len == range_capacity) return error.ProgramLimitExceeded;
                re.ranges[re.range_len] = .{ c, c };
                re.range_len += 1;
                set.range_count += 1;
            }

            fn addClass(self: *Compiler, set: *Set, class_in: Class, complement: bool) Error!void {
                var class = class_in;
                if (self.flags.icase and (class == .lower or class == .upper)) class = .alpha;
                for (0..128) |c| {
                    if (classHas(class, @intCast(c)) != complement) addAscii(set, @intCast(c));
                }
                const bit = @as(u16, 1) << @intCast(@intFromEnum(class));
                if (complement) set.not_classes |= bit else set.classes |= bit;
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
                    // A plain character alone is onechr() (allcases when
                    // insensitive); a collating element or a range is range().
                    var plain = true;
                    if (byte == '[' and (self.peek(1) == '.' or self.peek(1) == '=' or self.peek(1) == ':')) {
                        const kind = self.peek(1).?;
                        self.at += 2;
                        const name = try self.bracketName(kind);
                        switch (kind) {
                            '.' => {
                                start = try element(name);
                                plain = false;
                            },
                            '=' => {
                                // eclass: the character itself, or
                                // allcases() when insensitive.
                                const c = try element(name);
                                if (self.flags.icase) try self.addCases(set, c) else try self.addRange(set, c, c);
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
                    if (plain and !is_range and self.flags.icase) {
                        try self.addCases(set, start);
                    } else try self.addRange(set, start, end);
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

            /// parseqatom without the quantifier: one atom or constraint of
            /// an ARE or ERE.
            fn atom(self: *Compiler, depth: usize) Error!Atom {
                if (self.flags.bre) return self.breAtom(depth);
                const byte = self.src[self.at];
                switch (byte) {
                    '(' => {
                        self.at += 1;
                        if (!self.flags.ere and self.more() and self.src[self.at] == '?') {
                            self.at += 1;
                            const kind = self.peek(0) orelse return fail();
                            self.at += 1;
                            switch (kind) {
                                ':' => return .{ .kind = .plain, .node = try self.group(depth) },
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
                        return self.capturing(depth);
                    },
                    ')' => {
                        // A top-level `)` of an ERE is an ordinary character
                        // (REG_UPBOTCH); branch() stops on every other one.
                        self.at += 1;
                        try self.literal(')');
                        return .{ .kind = .plain };
                    },
                    '[' => {
                        // [[:<:]] and [[:>:]] are word constraints.
                        if (self.wordBracket()) |start| {
                            _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(if (start) Assertion.word_start else Assertion.word_end) });
                            return .{ .kind = .constraint };
                        }
                        self.at += 1;
                        try self.bracket();
                        return .{ .kind = .plain };
                    },
                    '.' => {
                        self.at += 1;
                        _ = try self.emit(.{ .op = .any });
                        return .{ .kind = .plain };
                    },
                    '^', '$' => {
                        self.at += 1;
                        _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(if (byte == '^') Assertion.bol else Assertion.eol) });
                        return .{ .kind = .constraint };
                    },
                    '*', '+', '?' => return fail(),
                    '{' => {
                        // A bound without an operand; `{` before a non-digit is literal.
                        var probe = self.at + 1;
                        if (self.flags.expanded) {
                            while (probe < self.src.len and spaceAt(self.src, probe) != 0) probe += spaceAt(self.src, probe);
                        }
                        if (probe < self.src.len and isDigit(self.src[probe])) return fail();
                        self.at += 1;
                        try self.literal('{');
                        return .{ .kind = .plain };
                    },
                    '\\' => {
                        self.at += 1;
                        const result = try self.escape(false);
                        switch (result.kind) {
                            .char => try self.literal(result.value),
                            .class, .complement => try self.classSet(result.class, result.kind == .complement),
                            .assert => {
                                _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(result.assertion) });
                                return .{ .kind = .constraint };
                            },
                            .backref => return self.backref(result.value),
                        }
                        return .{ .kind = .plain };
                    },
                    else => {
                        const lead = decode(self.src, self.at);
                        self.at += lead.len;
                        try self.literal(lead.cp);
                        return .{ .kind = .plain };
                    },
                }
            }

            /// `[[:<:]]` (true) or `[[:>:]]` (false) at the cursor, consumed.
            fn wordBracket(self: *Compiler) ?bool {
                if (self.src.len - self.at >= 7 and self.src[self.at + 1] == '[' and self.src[self.at + 2] == ':' and
                    (self.src[self.at + 3] == '<' or self.src[self.at + 3] == '>') and self.src[self.at + 4] == ':' and
                    self.src[self.at + 5] == ']' and self.src[self.at + 6] == ']')
                {
                    const start = self.src[self.at + 3] == '<';
                    self.at += 7;
                    return start;
                }
                return null;
            }

            /// brenext + parseqatom: one atom or constraint of a BRE.
            fn breAtom(self: *Compiler, depth: usize) Error!Atom {
                const byte = self.src[self.at];
                const last = self.bre_last;
                self.bre_last = .other;
                switch (byte) {
                    '*' => {
                        // Literal at the start, after `\(` or after `^`.
                        if (last == .other) return fail();
                        self.at += 1;
                        try self.literal('*');
                        return .{ .kind = .plain };
                    },
                    '^' => {
                        self.at += 1;
                        if (last == .empty or last == .open) {
                            _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(Assertion.bol) });
                            self.bre_last = .caret;
                            return .{ .kind = .constraint };
                        }
                        try self.literal('^');
                        return .{ .kind = .plain };
                    },
                    '$' => {
                        self.at += 1;
                        // An anchor at the end of the RE or before `\)`.
                        self.skipIgnorable();
                        if (!self.more() or (self.src[self.at] == '\\' and self.peek(1) == ')')) {
                            _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(Assertion.eol) });
                            return .{ .kind = .constraint };
                        }
                        try self.literal('$');
                        return .{ .kind = .plain };
                    },
                    '[' => {
                        if (self.wordBracket()) |start| {
                            _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(if (start) Assertion.word_start else Assertion.word_end) });
                            return .{ .kind = .constraint };
                        }
                        self.at += 1;
                        try self.bracket();
                        return .{ .kind = .plain };
                    },
                    '.' => {
                        self.at += 1;
                        _ = try self.emit(.{ .op = .any });
                        return .{ .kind = .plain };
                    },
                    '\\' => {
                        self.at += 1;
                        if (!self.more()) return fail();
                        const lead = decode(self.src, self.at);
                        self.at += lead.len;
                        switch (lead.cp) {
                            // A bound without an operand.
                            '{' => return fail(),
                            '(' => {
                                self.bre_last = .open;
                                const result = try self.capturing(depth);
                                self.bre_last = .other;
                                return result;
                            },
                            '<', '>' => {
                                _ = try self.emit(.{ .op = .assert, .arg = @intFromEnum(if (lead.cp == '<') Assertion.word_start else Assertion.word_end) });
                                return .{ .kind = .constraint };
                            },
                            '1'...'9' => return self.backref(lead.cp - '0'),
                            else => {
                                try self.literal(lead.cp);
                                return .{ .kind = .plain };
                            },
                        }
                    },
                    else => {
                        const lead = decode(self.src, self.at);
                        self.at += lead.len;
                        try self.literal(lead.cp);
                        return .{ .kind = .plain };
                    },
                }
            }

            /// The body of a group after its opening token.
            fn group(self: *Compiler, depth: usize) Error!u16 {
                self.open_groups += 1;
                const node = try self.alternation(true, depth + 1);
                self.open_groups -= 1;
                return node;
            }

            /// A capturing group (non-capturing inside a lookaround): the
            /// group's tree marked with its number, or a capture node
            /// around it when it already captures ("((x))").
            fn capturing(self: *Compiler, depth: usize) Error!Atom {
                var number: usize = 0;
                if (self.look_depth == 0) {
                    if (self.groups == states) return error.ProgramLimitExceeded;
                    self.groups += 1;
                    number = self.groups;
                    self.group_nodes[number] = no_sub;
                }
                var node = try self.group(depth);
                if (number == 0) return .{ .kind = .plain, .node = node };
                const re = self.re;
                if (re.subs[node].capno == 0) {
                    re.subs[node].flags |= cap;
                    re.subs[node].capno = @intCast(number);
                } else {
                    const inner = re.subs[node];
                    node = try self.newSub(.{ .op = .capture, .flags = inner.flags | cap, .capno = @intCast(number), .begin = inner.begin, .end = inner.end, .child = node });
                }
                self.group_nodes[number] = node;
                return .{ .kind = .capture, .node = node };
            }

            fn lookaround(self: *Compiler, kind: Look, depth: usize) Error!Atom {
                const look = try self.emit(.{ .op = .look, .arg = @intFromEnum(kind) });
                self.look_depth += 1;
                _ = try self.group(depth);
                self.look_depth -= 1;
                _ = try self.emit(.{ .op = .match });
                self.re.insts[look].x = @intCast(self.re.len - look);
                return .{ .kind = .constraint };
            }

            /// A back reference to a closed group outside lookarounds: a
            /// copy of the group's program without its constraints
            /// (dupnfa + removeconstraints), verified by dissection.
            fn backref(self: *Compiler, number: u32) Error!Atom {
                if (self.look_depth != 0 or number == 0 or number > self.groups) return fail();
                const target = self.group_nodes[number];
                if (target == no_sub) return fail();
                const re = self.re;
                re.has_backref = true;
                const start = re.len;
                if (target == dropped_sub) {
                    _ = try self.emit(.{ .op = .fail });
                } else {
                    const referenced = re.subs[target];
                    try self.copy(referenced.begin, referenced.end - referenced.begin);
                    for (re.insts[start..re.len]) |*inst| switch (inst.op) {
                        .assert => inst.* = .{ .op = .jump, .x = 1 },
                        .look => inst.op = .jump,
                        else => {},
                    };
                }
                const node = try self.newSub(.{ .op = .backref, .flags = backr, .backno = @intCast(number), .begin = @intCast(start), .end = @intCast(re.len) });
                return .{ .kind = .backref, .node = node };
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

            /// The quantifier after an atom (m = n = 1, no preference, when
            /// there is none).
            fn quantifier(self: *Compiler) Error!Quant {
                self.skipIgnorable();
                if (!self.more()) return .{};
                if (self.flags.bre) {
                    if (self.src[self.at] == '*') {
                        self.at += 1;
                        return .{ .m = 0, .n = infinite, .prefer = longer };
                    }
                    if (self.src[self.at] != '\\' or self.peek(1) != '{') return .{};
                    self.at += 2;
                    const range = try self.bounds();
                    if (!self.more() or self.src[self.at] != '\\' or self.peek(1) != '}') return fail();
                    self.at += 2;
                    return .{ .m = range.m, .n = range.n, .prefer = if (range.range) longer else 0 };
                }
                const advanced = !self.flags.ere;
                switch (self.src[self.at]) {
                    '*', '+', '?' => |byte| {
                        self.at += 1;
                        var prefer = longer;
                        if (advanced and self.more() and self.src[self.at] == '?') {
                            self.at += 1;
                            prefer = shorter;
                        }
                        return .{ .m = if (byte == '+') 1 else 0, .n = if (byte == '?') 1 else infinite, .prefer = prefer };
                    },
                    '{' => {
                        var probe = self.at + 1;
                        if (self.flags.expanded) {
                            while (probe < self.src.len and spaceAt(self.src, probe) != 0) probe += spaceAt(self.src, probe);
                        }
                        if (probe >= self.src.len or !isDigit(self.src[probe])) return .{};
                        self.at += 1;
                        const range = try self.bounds();
                        if (!self.more() or self.src[self.at] != '}') return fail();
                        self.at += 1;
                        var prefer: u8 = if (range.range) longer else 0;
                        if (advanced and self.more() and self.src[self.at] == '?') {
                            self.at += 1;
                            // {m}? passes the operand's preference through.
                            if (range.range) prefer = shorter;
                        }
                        return .{ .m = range.m, .n = range.n, .prefer = prefer };
                    },
                    else => return .{},
                }
            }

            /// `m`, `m,` or `m,n` inside a bound (`range`: the comma forms).
            fn bounds(self: *Compiler) Error!struct { m: u32, n: u32, range: bool } {
                self.skipBoundSpace();
                const low = try self.boundNumber();
                var high = low;
                var range = false;
                self.skipBoundSpace();
                if (self.more() and self.src[self.at] == ',') {
                    self.at += 1;
                    self.skipBoundSpace();
                    high = if (self.more() and isDigit(self.src[self.at])) try self.boundNumber() else infinite;
                    self.skipBoundSpace();
                    if (low > high) return fail();
                    range = true;
                }
                return .{ .m = low, .n = high, .range = range };
            }

            /// Repeats the block [start, len) between `low` and `high`
            /// times. Subres created since `mark` lie in the block; the
            /// first copy keeps them (it moves by one when a leading split
            /// is inserted).
            fn repeat(self: *Compiler, start: usize, mark: usize, low: u32, high: u32) Error!void {
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
                        try self.insert(start, 1, mark);
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
                    try self.insert(start, 1, mark);
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

            fn bound16(value: u32) u16 {
                return if (value == infinite) sub_infinite else @intCast(value);
            }

            /// The quantifier structure of a messy atom at [start, len)
            /// (regcomp.c parseqatom after "It's quantifier time").
            fn quantify(self: *Compiler, atom_node: u16, kind: AtomKind, start: usize, mark: usize, q: Quant) Error!u16 {
                const re = self.re;
                const atom_flags = re.subs[atom_node].flags;
                if (kind == .backref) {
                    // Back references repeat internally.
                    try self.repeat(start, mark, q.m, q.n);
                    const node = &re.subs[atom_node];
                    node.begin = @intCast(start);
                    node.end = @intCast(re.len);
                    node.min = bound16(q.m);
                    node.max = bound16(q.n);
                    node.flags |= combine(q.prefer, atom_flags);
                    return atom_node;
                }
                const preference = atom_flags & (longer | shorter | mixed);
                if (q.m == 1 and q.n == 1 and (q.prefer == 0 or preference == 0 or q.prefer == preference)) return atom_node;
                if (atom_flags & (cap | backr) == 0) {
                    // No submatches inside: one plain node.
                    try self.repeat(start, mark, q.m, q.n);
                    self.dropSubs(mark);
                    return self.newSub(.{ .flags = combine(q.prefer, atom_flags), .begin = @intCast(start), .end = @intCast(re.len) });
                }
                if (q.m > 0 and atom_flags & backr == 0) {
                    // x{m,n} is x{m-1,n-1}x: captures come from the last copy.
                    const atom_end = re.len;
                    try self.copy(start, atom_end - start);
                    try self.repeat(atom_end, re.sub_len, q.m - 1, if (q.n == infinite) infinite else q.n - 1);
                    const prefix_len = re.len - atom_end;
                    self.rotate(start, atom_end, re.len);
                    self.shiftSubs(mark, prefix_len);
                    const f = combine(q.prefer, atom_flags);
                    const prefix = try self.newSub(.{ .flags = prefOf(f), .begin = @intCast(start), .end = @intCast(start + prefix_len), .sibling = atom_node });
                    return self.newSub(.{ .op = .concat, .flags = f, .begin = @intCast(start), .end = @intCast(re.len), .child = prefix });
                }
                // The general case: an iteration node over the atom.
                try self.repeat(start, mark, q.m, q.n);
                return self.newSub(.{ .op = .iter, .flags = combine(q.prefer, atom_flags), .min = bound16(q.m), .max = bound16(q.n), .begin = @intCast(start), .end = @intCast(re.len), .child = atom_node });
            }

            /// Whether the cursor is at the end of the current branch.
            fn branchEnd(self: *const Compiler) bool {
                const byte = self.src[self.at];
                if (self.flags.bre) return byte == '\\' and self.peek(1) == ')';
                if (byte == '|') return true;
                if (byte == ')') return self.open_groups > 0 or !self.flags.ere;
                return false;
            }

            /// parsebranch: atoms and constraints up to `|`, `)` or the
            /// end. Plain atoms gather in segments; every messy atom
            /// (captures, back references or a preference clash) closes
            /// one, and the segments nest to the right as parseqatom's
            /// recursion builds them. Returns the branch's subre (no_sub
            /// inside lookarounds).
            fn branch(self: *Compiler, depth: usize) Error!u16 {
                const re = self.re;
                const tree = self.look_depth == 0;
                var segment_begin: usize = re.len;
                var segment_flags: u8 = 0;
                var segment_items = false;
                // Segments so far, newest first (linked through `sibling`).
                var last_segment: u16 = no_sub;
                while (true) {
                    self.skipIgnorable();
                    if (!self.more() or self.branchEnd()) break;
                    const start = re.len;
                    const mark = re.sub_len;
                    const item = try self.atom(depth);
                    if (item.kind == .constraint) {
                        segment_items = true;
                        continue;
                    }
                    const q = try self.quantifier();
                    if (self.flags.bre and q.n != 1) self.bre_last = .other;
                    if (q.m == 0 and q.n == 0) {
                        re.len = start;
                        self.dropSubs(mark);
                        segment_items = true;
                        continue;
                    }
                    const atom_flags: u8 = if (item.node != no_sub) re.subs[item.node].flags else 0;
                    const f = segment_flags | q.prefer | atom_flags;
                    if (!tree or (item.kind == .plain and !isMessy(up(f)))) {
                        try self.repeat(start, mark, q.m, q.n);
                        self.dropSubs(mark);
                        segment_flags = f;
                        segment_items = true;
                        continue;
                    }
                    var atom_node = item.node;
                    if (atom_node == no_sub) atom_node = try self.newSub(.{ .begin = @intCast(start), .end = @intCast(re.len) });
                    const t_flags = combine(q.prefer, re.subs[atom_node].flags);
                    const x = try self.quantify(atom_node, item.kind, start, mark, q);
                    const prefix = try self.newSub(.{ .flags = segment_flags, .vacuous = !segment_items, .begin = @intCast(segment_begin), .end = @intCast(start) });
                    const t = try self.newSub(.{ .op = .concat, .flags = t_flags, .begin = @intCast(start), .end = @intCast(re.len), .child = x });
                    re.subs[prefix].sibling = t;
                    last_segment = try self.newSub(.{ .op = .concat, .flags = segment_flags, .begin = @intCast(segment_begin), .end = @intCast(re.len), .child = prefix, .sibling = last_segment });
                    segment_begin = re.len;
                    segment_flags = 0;
                    segment_items = false;
                }
                if (!tree) return no_sub;
                var rest: u16 = no_sub;
                if (segment_items or last_segment == no_sub) rest = try self.newSub(.{ .flags = segment_flags, .begin = @intCast(segment_begin), .end = @intCast(re.len) });
                var segment = last_segment;
                while (segment != no_sub) {
                    const previous = re.subs[segment].sibling;
                    rest = self.assemble(segment, rest);
                    segment = previous;
                }
                return rest;
            }

            /// The end of parseqatom for one segment `top` ('.' over its
            /// prefix and t = '.' over the messy atom X) given the rest of
            /// the branch (no_sub when nothing follows X).
            fn assemble(self: *Compiler, top: u16, rest: u16) u16 {
                const subs = &self.re.subs;
                subs[top].sibling = no_sub;
                const prefix = subs[top].child;
                const t = subs[prefix].sibling;
                const x = subs[t].child;
                if (rest != no_sub) {
                    subs[x].sibling = rest;
                    subs[t].flags |= combine(subs[t].flags, subs[rest].flags);
                    subs[t].end = subs[rest].end;
                    subs[top].flags |= combine(subs[top].flags, subs[t].flags);
                    subs[top].end = subs[rest].end;
                    if (subs[prefix].vacuous) {
                        subs[top].child = x;
                    } else if (subs[x].op == .plain and subs[rest].op == .plain and !isMessy(up(subs[x].flags | subs[rest].flags))) {
                        subs[t].op = .plain;
                        subs[t].flags = combine(subs[x].flags, subs[rest].flags);
                        subs[t].child = no_sub;
                    }
                    return top;
                }
                subs[prefix].sibling = x;
                subs[x].sibling = no_sub;
                subs[top].flags |= combine(subs[top].flags, subs[x].flags);
                subs[top].end = subs[x].end;
                if (subs[prefix].vacuous) return x;
                return top;
            }

            /// parse: branches separated by `|` (none in BREs), up to the
            /// group's closing token (`group`) or the end.
            fn alternation(self: *Compiler, in_group: bool, depth: usize) Error!u16 {
                if (depth > self.depth_limit) return error.StatementTooComplex;
                const re = self.re;
                const tree = self.look_depth == 0;
                const begin = re.len;
                const mark = re.sub_len;
                var placeholder = try self.emit(.{ .op = .jump, .x = 1 });
                // Pending end jumps, linked through `arg` (index + 1).
                var pending: u32 = 0;
                const first = try self.branch(depth);
                var last = first;
                var count: usize = 1;
                var flags: u8 = longer;
                if (tree) flags |= up(flags | re.subs[first].flags);
                while (!self.flags.bre and self.more() and self.src[self.at] == '|') {
                    self.at += 1;
                    const jump = try self.emit(.{ .op = .jump, .arg = pending });
                    pending = @intCast(jump + 1);
                    re.insts[placeholder] = .{ .op = .split, .x = 1, .y = @intCast(re.len - placeholder) };
                    placeholder = try self.emit(.{ .op = .jump, .x = 1 });
                    const next = try self.branch(depth);
                    if (tree) {
                        re.subs[last].sibling = next;
                        last = next;
                        flags |= up(flags | re.subs[next].flags);
                    }
                    count += 1;
                }
                while (pending != 0) {
                    const jump = pending - 1;
                    pending = re.insts[jump].arg;
                    re.insts[jump].arg = 0;
                    re.insts[jump].x = @intCast(re.len - jump);
                }
                if (in_group) {
                    if (self.flags.bre) {
                        if (!self.more() or self.src[self.at] != '\\' or self.peek(1) != ')') return fail();
                        self.at += 2;
                    } else {
                        if (!self.more() or self.src[self.at] != ')') return fail();
                        self.at += 1;
                    }
                } else if (self.more()) return fail();
                if (!tree) return no_sub;
                if (count == 1) return first;
                if (!isMessy(flags)) {
                    // No interesting innards: one plain node.
                    re.sub_len = mark;
                    return self.newSub(.{ .flags = flags, .begin = @intCast(begin), .end = @intCast(re.len) });
                }
                return self.newSub(.{ .op = .alt, .flags = flags, .begin = @intCast(begin), .end = @intCast(re.len), .child = first });
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
                            self.flags.bre = false;
                            self.at = 4;
                        },
                        else => return fail(),
                    }
                }
                if (self.flags.ere) return;
                if (self.src.len - self.at >= 3 and self.src[self.at] == '(' and self.src[self.at + 1] == '?' and isAlpha(self.src[self.at + 2])) {
                    self.at += 2;
                    while (self.more() and isAlpha(self.src[self.at])) : (self.at += 1) switch (self.src[self.at]) {
                        'b' => {
                            self.flags.bre = true;
                            self.flags.ere = true;
                            self.flags.quote = false;
                        },
                        'c' => self.flags.icase = false,
                        'e' => {
                            self.flags.ere = true;
                            self.flags.bre = false;
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
                        'q' => {
                            self.flags.quote = true;
                            self.flags.ere = true;
                            self.flags.bre = true;
                        },
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
        /// group and lookaround nesting (54001 beyond).
        pub fn compile(self: *Self, pattern: []const u8, flags: Flags, depth_limit: usize) Error!void {
            self.len = 0;
            self.set_len = 0;
            self.range_len = 0;
            self.sub_len = 0;
            self.root = no_sub;
            self.groups = 0;
            self.has_backref = false;
            // pg_regcomp: REG_QUOTE with REG_EXPANDED or REG_NEWLINE bits
            // is REG_INVARG.
            if (flags.quote and (flags.expanded or flags.nlstop or flags.nlanch)) return error.InvalidRegularExpression;
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
                self.root = try compiler.newSub(.{ .end = @intCast(self.len) });
            } else self.root = try compiler.alternation(false, 0);
            _ = try compiler.emit(.{ .op = .match });
            self.groups = compiler.groups;
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
            } else {
                if (set.classes | set.not_classes != 0) {
                    for (0..class_names.len) |class_index| {
                        const bit = @as(u16, 1) << @intCast(class_index);
                        if (set.classes & bit == 0 and set.not_classes & bit == 0) continue;
                        const member = highClassHas(@enumFromInt(class_index), cp);
                        if ((set.classes & bit != 0 and member) or (set.not_classes & bit != 0 and !member)) {
                            hit = true;
                            break;
                        }
                    }
                }
                if (!hit) for (self.ranges[set.range_start..][0..set.range_count]) |range| {
                    if (cp >= range[0] and cp <= range[1]) {
                        hit = true;
                        break;
                    }
                };
            }
            return hit != set.negated;
        }

        /// The character before byte offset `at` (null at the start).
        fn before(text: []const u8, at: usize) ?u32 {
            if (at == 0) return null;
            return decode(text, prevChar(text, at)).cp;
        }

        fn wordAt(cp: ?u32) bool {
            return if (cp) |c| wordChar(c) else false;
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

        /// Epsilon closure of `pc0` at byte offset `at` into `list`; a
        /// thread reaching `exit` stays there (the block has matched).
        fn addThread(self: *const Self, list: *List, stack: *[2 * states + 2]u16, pc0: usize, exit: usize, text: []const u8, at: usize, control: ?*types.ExecutionControl) Error!void {
            var top: usize = 0;
            stack[top] = @intCast(pc0);
            top += 1;
            while (top != 0) {
                top -= 1;
                const pc: usize = stack[top];
                if (list.has(pc)) continue;
                list.add(pc);
                if (pc == exit) continue;
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
                    .look => {
                        const kind: Look = @enumFromInt(inst.arg);
                        const continuation: usize = @intCast(@as(i64, @intCast(pc)) + inst.x);
                        const sub_exit = continuation - 1;
                        const found = switch (kind) {
                            .ahead, .ahead_not => (try self.simulate(pc + 1, sub_exit, text, at, text.len, at, .shortest, control)) != null,
                            .behind, .behind_not => (try self.simulate(pc + 1, sub_exit, text, 0, at, 0, .behind, control)) != null,
                        };
                        if (found == (kind == .ahead or kind == .behind)) {
                            stack[top] = @intCast(continuation);
                            top += 1;
                        }
                    },
                    .char, .any, .set, .match, .fail => {},
                }
            }
        }

        fn consumes(self: *const Self, inst: Inst, cp: u32) bool {
            return switch (inst.op) {
                .char => cp == inst.arg or (inst.fold and cp == @as(u32, @intCast(inst.x))),
                .any => !(self.flags.nlstop and cp == '\n'),
                .set => self.inSet(inst.arg, cp),
                else => false,
            };
        }

        /// exists: unanchored from `begin`, the first position where some
        /// match ends. behind: unanchored from `begin`, `stop` when a match
        /// ends exactly there (lookbehind). longest: anchored at `begin`,
        /// the last end at or before `stop`. shortest: anchored at
        /// `begin`, the first end in [min, stop].
        const Mode = enum { exists, behind, longest, shortest };

        /// Simulates the block [entry, exit) over `text`; null when no
        /// match qualifies.
        fn simulate(self: *const Self, entry: usize, exit: usize, text: []const u8, begin: usize, stop: usize, min: usize, mode: Mode, control: ?*types.ExecutionControl) Error!?usize {
            var lists: [2]List = undefined;
            lists[0].len = 0;
            lists[1].len = 0;
            var stack: [2 * states + 2]u16 = undefined;
            var current: usize = 0;
            var at = begin;
            const unanchored = mode == .exists or mode == .behind;
            var last: ?usize = null;
            while (true) {
                if (control) |active| try active.checkpoint();
                const list = &lists[current];
                if (unanchored or at == begin) try self.addThread(list, &stack, entry, exit, text, at, control);
                const matched = list.has(exit);
                switch (mode) {
                    .exists => if (matched) return at,
                    .behind => if (at == stop) return if (matched) at else null,
                    .longest => if (matched) {
                        last = at;
                    },
                    .shortest => if (matched and at >= min) return at,
                }
                if (at >= stop) return last;
                if (list.len == 0 and !unanchored) return last;
                const step = decode(text, at);
                const next = &lists[1 - current];
                next.len = 0;
                for (list.dense[0..list.len]) |pc| {
                    if (pc == exit) continue;
                    if (self.consumes(self.insts[pc], step.cp)) try self.addThread(next, &stack, pc + 1, exit, text, at + step.len, control);
                }
                list.len = 0;
                current = 1 - current;
                at += step.len;
            }
        }

        /// The leftmost start of a match of the whole program at or after
        /// `from`: threads keep their start, the oldest wins a state, and
        /// the scan ends once no thread older than the best match remains.
        fn leftmostStart(self: *const Self, text: []const u8, from: usize, control: ?*types.ExecutionControl) Error!?usize {
            const exit = self.len - 1;
            var lists: [2]List = undefined;
            lists[0].len = 0;
            lists[1].len = 0;
            var starts: [2][states]u32 = undefined;
            var stack: [2 * states + 2]u16 = undefined;
            var current: usize = 0;
            var at = from;
            var best: ?usize = null;
            while (true) {
                if (control) |active| try active.checkpoint();
                const list = &lists[current];
                const seen = &starts[current];
                if (best == null) {
                    const old = list.len;
                    try self.addThread(list, &stack, 0, exit, text, at, control);
                    for (list.dense[old..list.len]) |pc| seen[pc] = @intCast(at);
                }
                if (list.has(exit)) {
                    const start: usize = seen[exit];
                    if (best == null or start < best.?) best = start;
                }
                if (best) |found| {
                    var kept: usize = 0;
                    for (0..list.len) |index| {
                        const pc = list.dense[index];
                        if (pc != exit and seen[pc] < found) {
                            list.dense[kept] = pc;
                            list.sparse[pc] = @intCast(kept);
                            kept += 1;
                        }
                    }
                    list.len = kept;
                    if (kept == 0) return found;
                }
                if (at >= text.len) return best;
                const step = decode(text, at);
                const next = &lists[1 - current];
                const next_seen = &starts[1 - current];
                next.len = 0;
                for (list.dense[0..list.len]) |pc| {
                    if (pc == exit or !self.consumes(self.insts[pc], step.cp)) continue;
                    const old = next.len;
                    try self.addThread(next, &stack, pc + 1, exit, text, at + step.len, control);
                    for (next.dense[old..next.len]) |added| next_seen[added] = seen[pc];
                }
                list.len = 0;
                current = 1 - current;
                at += step.len;
            }
        }

        /// Whether the expression matches anywhere in ex.text (the ~
        /// operators; caps hold the groups when it has back references).
        pub fn search(self: *const Self, ex: *Exec) Error!bool {
            if (!self.has_backref) return (try self.simulate(0, self.len - 1, ex.text, 0, ex.text.len, 0, .exists, ex.control)) != null;
            return self.execute(ex, 0, false);
        }

        /// The leftmost match at or after byte offset `from` (pg_regexec):
        /// ex.caps[0] the whole match and, with `want_groups`, ex.caps[n]
        /// group n. False when there is none.
        pub fn execute(self: *const Self, ex: *Exec, from: usize, want_groups: bool) Error!bool {
            if (ex.caps.len == 0 or (self.has_backref and ex.caps.len < self.groups + 1)) return error.ProgramLimitExceeded;
            for (ex.caps) |*entry| entry.* = .{};
            const text = ex.text;
            const exit = self.len - 1;
            const prefer_short = self.root != no_sub and self.subs[self.root].flags & shorter != 0;
            if (!self.has_backref) {
                const first = (try self.leftmostStart(text, from, ex.control)) orelse return false;
                const found = if (prefer_short)
                    try self.simulate(0, exit, text, first, text.len, first, .shortest, ex.control)
                else
                    try self.simulate(0, exit, text, first, text.len, 0, .longest, ex.control);
                const end = found orelse return false;
                if (want_groups and self.groups > 0 and self.root != no_sub) {
                    if (!try self.dissect(ex, self.root, first, end)) return false;
                }
                ex.caps[0] = .{ .start = @intCast(first), .end = @intCast(end) };
                return true;
            }
            // cfindloop: rounds from `close`, each up to the earliest end of
            // any candidate match; every start of the round tries all its
            // candidate ends, best first, until a dissection verifies the
            // back references. A new round needs close + 1 < the end.
            var close = from;
            while (true) {
                const earliest = (try self.simulate(0, exit, text, close, text.len, 0, .exists, ex.control)) orelse return false;
                var begin = close;
                while (true) {
                    if (try self.verifyStart(ex, begin, prefer_short)) return true;
                    if (begin >= earliest) break;
                    begin = nextChar(text, begin);
                }
                if (earliest >= text.len) return false;
                close = nextChar(text, earliest);
                if (close >= text.len) return false;
            }
        }

        /// All candidate ends of one start for an expression with back
        /// references: the first that dissects sets the match.
        fn verifyStart(self: *const Self, ex: *Exec, begin: usize, prefer_short: bool) Error!bool {
            const text = ex.text;
            const exit = self.len - 1;
            if (prefer_short) {
                var low = begin;
                while (try self.simulate(0, exit, text, begin, text.len, low, .shortest, ex.control)) |end| {
                    self.zapGroups(ex);
                    if (try self.dissect(ex, self.root, begin, end)) {
                        ex.caps[0] = .{ .start = @intCast(begin), .end = @intCast(end) };
                        return true;
                    }
                    if (end == text.len) return false;
                    low = nextChar(text, end);
                }
                return false;
            }
            var high = text.len;
            while (try self.simulate(0, exit, text, begin, high, 0, .longest, ex.control)) |end| {
                self.zapGroups(ex);
                if (try self.dissect(ex, self.root, begin, end)) {
                    ex.caps[0] = .{ .start = @intCast(begin), .end = @intCast(end) };
                    return true;
                }
                if (end == begin) return false;
                high = prevChar(text, end);
            }
            return false;
        }

        fn zapGroups(self: *const Self, ex: *Exec) void {
            _ = self;
            for (ex.caps[1..]) |*entry| entry.* = .{};
        }

        /// zaptreesubs: clears the groups captured inside subtree `t`.
        fn zap(self: *const Self, ex: *Exec, t: u16) void {
            const node = &self.subs[t];
            if (node.capno > 0 and node.capno < ex.caps.len) ex.caps[node.capno] = .{};
            var child = node.child;
            while (child != no_sub) : (child = self.subs[child].sibling) self.zap(ex, child);
        }

        /// The longest match of node `t` anchored at `begin` ending at or
        /// before `stop` (a back reference to a captured group compares
        /// the captured text: dfa_backref).
        fn nodeLongest(self: *const Self, ex: *Exec, t: u16, begin: usize, stop: usize) Error!?usize {
            const node = &self.subs[t];
            if (node.op == .backref and ex.caps[node.backno].start >= 0) return self.backrefSpan(ex, node, begin, begin, stop, false);
            return self.simulate(node.begin, node.end, ex.text, begin, stop, 0, .longest, ex.control);
        }

        /// The shortest match of node `t` anchored at `begin` ending in
        /// [min, stop].
        fn nodeShortest(self: *const Self, ex: *Exec, t: u16, begin: usize, min: usize, stop: usize) Error!?usize {
            const node = &self.subs[t];
            if (node.op == .backref and ex.caps[node.backno].start >= 0) return self.backrefSpan(ex, node, begin, min, stop, true);
            return self.simulate(node.begin, node.end, ex.text, begin, stop, min, .shortest, ex.control);
        }

        fn sameChar(self: *const Self, a: u32, b: u32) bool {
            return a == b or (self.flags.icase and unicode_case.toLower(a) == unicode_case.toLower(b));
        }

        /// Compares the captured text `ref` with the text at `at`; the
        /// position after it, or null.
        fn matchRef(self: *const Self, ex: *Exec, ref: []const u8, at: usize) Error!?usize {
            if (ex.control) |active| try active.checkpoint();
            var p = at;
            var r: usize = 0;
            while (r < ref.len) {
                if (p >= ex.text.len) return null;
                const want = decode(ref, r);
                const got = decode(ex.text, p);
                if (!self.sameChar(want.cp, got.cp)) return null;
                r += want.len;
                p += got.len;
            }
            return p;
        }

        /// dfa_backref in characters: repetitions of the captured text
        /// from `start` ending in [min, stop], fewest or most first.
        fn backrefSpan(self: *const Self, ex: *Exec, node: *const Sub, start: usize, min: usize, stop: usize, fewest: bool) Error!?usize {
            const captured = ex.caps[node.backno];
            const ref = ex.text[@intCast(captured.start)..@intCast(captured.end)];
            const length = charCount(ref, 0, ref.len);
            if (length == 0) return if (min == start) start else null;
            const min_reps: usize = if (min <= start) 0 else (charCount(ex.text, start, min) - 1) / length + 1;
            var max_reps: usize = charCount(ex.text, start, stop) / length;
            const low = @max(min_reps, node.min);
            if (node.max != sub_infinite and max_reps > node.max) max_reps = node.max;
            if (max_reps < low) return null;
            if (fewest and low == 0) return start;
            var p = start;
            var reps: usize = 0;
            while (reps < max_reps) {
                p = (try self.matchRef(ex, ref, p)) orelse break;
                reps += 1;
                if (fewest and reps >= low) break;
            }
            return if (reps >= low) p else null;
        }

        /// cdissect: whether node `t` matches text[begin..end) with its
        /// back references satisfied, recording its groups.
        fn dissect(self: *const Self, ex: *Exec, t: u16, begin: usize, end: usize) Error!bool {
            if (ex.control) |active| try active.checkpoint();
            const node = &self.subs[t];
            const ok = switch (node.op) {
                .plain => true,
                .backref => try self.backrefDissect(ex, node, begin, end),
                .concat => if (self.subs[node.child].flags & shorter != 0) try self.concatShortest(ex, node, begin, end) else try self.concatLongest(ex, node, begin, end),
                .alt => try self.alternative(ex, node, begin, end),
                .iter => if (self.subs[node.child].flags & shorter != 0) try self.iterShortest(ex, node, begin, end) else try self.iterLongest(ex, node, begin, end),
                .capture => try self.dissect(ex, node.child, begin, end),
            };
            if (ok and node.capno > 0 and node.capno < ex.caps.len) ex.caps[node.capno] = .{ .start = @intCast(begin), .end = @intCast(end) };
            return ok;
        }

        /// ccondissect: the left child takes the longest share.
        fn concatLongest(self: *const Self, ex: *Exec, node: *const Sub, begin: usize, end: usize) Error!bool {
            const left = node.child;
            const right = self.subs[left].sibling;
            var mid = (try self.nodeLongest(ex, left, begin, end)) orelse return false;
            while (true) {
                if ((try self.nodeLongest(ex, right, mid, end)) == end) {
                    if (try self.dissect(ex, left, begin, mid)) {
                        if (try self.dissect(ex, right, mid, end)) return true;
                        self.zap(ex, left);
                    }
                }
                if (mid == begin) return false;
                mid = (try self.nodeLongest(ex, left, begin, prevChar(ex.text, mid))) orelse return false;
            }
        }

        /// crevcondissect: the left child takes the shortest share.
        fn concatShortest(self: *const Self, ex: *Exec, node: *const Sub, begin: usize, end: usize) Error!bool {
            const left = node.child;
            const right = self.subs[left].sibling;
            var mid = (try self.nodeShortest(ex, left, begin, begin, end)) orelse return false;
            while (true) {
                if ((try self.nodeLongest(ex, right, mid, end)) == end) {
                    if (try self.dissect(ex, left, begin, mid)) {
                        if (try self.dissect(ex, right, mid, end)) return true;
                        self.zap(ex, left);
                    }
                }
                if (mid == end) return false;
                mid = (try self.nodeShortest(ex, left, begin, nextChar(ex.text, mid), end)) orelse return false;
            }
        }

        /// caltdissect: the first alternative that matches the whole span.
        fn alternative(self: *const Self, ex: *Exec, node: *const Sub, begin: usize, end: usize) Error!bool {
            var child = node.child;
            while (child != no_sub) : (child = self.subs[child].sibling) {
                if ((try self.nodeLongest(ex, child, begin, end)) == end) {
                    if (try self.dissect(ex, child, begin, end)) return true;
                }
            }
            return false;
        }

        /// cbrdissect: the span is a whole number of copies of the group.
        fn backrefDissect(self: *const Self, ex: *Exec, node: *const Sub, begin: usize, end: usize) Error!bool {
            const captured = ex.caps[node.backno];
            if (captured.start < 0) return false;
            const ref = ex.text[@intCast(captured.start)..@intCast(captured.end)];
            const length = charCount(ref, 0, ref.len);
            if (length == 0) return begin == end;
            if (begin == end) return node.min == 0;
            const total = charCount(ex.text, begin, end);
            if (total % length != 0) return false;
            const reps = total / length;
            if (reps < node.min or (node.max != sub_infinite and reps > node.max)) return false;
            var p = begin;
            for (0..reps) |_| p = (try self.matchRef(ex, ref, p)) orelse return false;
            return true;
        }

        fn endpoints(ex: *Exec, count: usize) Error![]u32 {
            if (ex.work.len - ex.used < count) return error.ProgramLimitExceeded;
            const points = ex.work[ex.used..][0..count];
            ex.used += count;
            return points;
        }

        /// Verifies iterations nverified+1..k of an iteration's child; the
        /// first failing one (k + 1 when all hold).
        fn verify(self: *const Self, ex: *Exec, child: u16, points: []const u32, verified: *usize, k: usize) Error!usize {
            var index = verified.* + 1;
            while (index <= k) : (index += 1) {
                self.zap(ex, child);
                if (!try self.dissect(ex, child, points[index - 1], points[index])) return index;
                verified.* = index;
            }
            return index;
        }

        /// citerdissect: greedy iterations, each the longest the child
        /// allows, backtracking shorter.
        fn iterLongest(self: *const Self, ex: *Exec, node: *const Sub, begin: usize, end: usize) Error!bool {
            const text = ex.text;
            const child = node.child;
            const min_matches: usize = if (node.min == 0) 1 else node.min;
            var max_matches: usize = charCount(text, begin, end);
            if (node.max != sub_infinite and max_matches > node.max) max_matches = node.max;
            if (max_matches < min_matches) max_matches = min_matches;
            const points = try endpoints(ex, max_matches + 1);
            defer ex.used -= points.len;
            points[0] = @intCast(begin);
            var verified: usize = 0;
            var k: usize = 1;
            var limit = end;
            outer: while (k > 0) {
                if (try self.nodeLongest(ex, child, points[k - 1], limit)) |found| {
                    points[k] = @intCast(found);
                    if (verified >= k) verified = k - 1;
                    if (found != end) {
                        if (k >= max_matches) {
                            k -= 1;
                        } else if (!(found == points[k - 1] and (k >= min_matches or min_matches - k < charCount(text, found, end)))) {
                            k += 1;
                            limit = end;
                            continue :outer;
                        }
                    } else if (k >= min_matches) {
                        const failed = try self.verify(ex, child, points, &verified, k);
                        if (failed > k) return true;
                        k = failed;
                    }
                } else k -= 1;
                // Consider shorter versions of the k'th iteration.
                while (k > 0) : (k -= 1) {
                    const previous: usize = points[k - 1];
                    if (points[k] > previous) {
                        limit = prevChar(text, points[k]);
                        if (limit > previous or (k < min_matches and min_matches - k >= charCount(text, previous, end))) break;
                    }
                }
            }
            return node.min == 0 and begin == end;
        }

        /// creviterdissect: non-greedy iterations, each the shortest the
        /// child allows, backtracking longer.
        fn iterShortest(self: *const Self, ex: *Exec, node: *const Sub, begin: usize, end: usize) Error!bool {
            const text = ex.text;
            const child = node.child;
            var min_matches: usize = node.min;
            if (min_matches == 0) {
                if (begin == end) return true;
                min_matches = 1;
            }
            var max_matches: usize = charCount(text, begin, end);
            if (node.max != sub_infinite and max_matches > node.max) max_matches = node.max;
            if (max_matches < min_matches) max_matches = min_matches;
            const points = try endpoints(ex, max_matches + 1);
            defer ex.used -= points.len;
            points[0] = @intCast(begin);
            var verified: usize = 0;
            var k: usize = 1;
            var limit = begin;
            outer: while (k > 0) {
                // No zero-length iteration unless needed to reach min.
                if (limit == points[k - 1] and limit != end and (k >= min_matches or min_matches - k < charCount(text, limit, end))) limit = nextChar(text, limit);
                if (k >= max_matches) limit = end;
                if (try self.nodeShortest(ex, child, points[k - 1], limit, end)) |found| {
                    points[k] = @intCast(found);
                    if (verified >= k) verified = k - 1;
                    if (found != end) {
                        if (k >= max_matches) {
                            k -= 1;
                        } else {
                            k += 1;
                            limit = points[k - 1];
                            continue :outer;
                        }
                    } else if (k >= min_matches) {
                        const failed = try self.verify(ex, child, points, &verified, k);
                        if (failed > k) return true;
                        k = failed;
                    }
                } else k -= 1;
                // Consider longer versions of the k'th iteration.
                while (k > 0) : (k -= 1) {
                    if (points[k] < end) {
                        limit = nextChar(text, points[k]);
                        break;
                    }
                }
            }
            return false;
        }
    };
}

/// A compiled expression with the storage its matches need (sized from
/// the text capacity: iteration end points of dissection).
pub fn Matcher(comptime states: usize, comptime text_bytes: usize) type {
    return struct {
        const Self = @This();
        re: Regex(states) = .{},
        caps: [states + 1]Capture = undefined,
        work: [2 * text_bytes + 16]u32 = undefined,

        pub fn compile(self: *Self, pattern: []const u8, flags: Flags, depth_limit: usize) Error!void {
            return self.re.compile(pattern, flags, depth_limit);
        }

        /// Capturing groups of the compiled expression.
        pub fn groups(self: *const Self) usize {
            return self.re.groups;
        }

        fn exec(self: *Self, text: []const u8, control: ?*types.ExecutionControl) Exec {
            return .{ .text = text, .caps = self.caps[0 .. self.re.groups + 1], .work = &self.work, .control = control };
        }

        /// Whether the expression matches somewhere in `text`.
        pub fn search(self: *Self, text: []const u8, control: ?*types.ExecutionControl) Error!bool {
            var ex = self.exec(text, control);
            return self.re.search(&ex);
        }

        /// The leftmost match at or after byte offset `from`: caps[0] and,
        /// with `want_groups`, caps[1..groups + 1] (byte offsets, -1 for a
        /// group that did not participate).
        pub fn match(self: *Self, text: []const u8, from: usize, want_groups: bool, control: ?*types.ExecutionControl) Error!bool {
            var ex = self.exec(text, control);
            return self.re.execute(&ex, from, want_groups);
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
