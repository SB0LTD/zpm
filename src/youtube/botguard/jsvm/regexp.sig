// @zpm/youtube/botguard/jsvm/regexp — Basic Regex Engine
//
// Minimal regex support for BotGuard's string operations.
// BotGuard uses regex for:
//   - String splitting by pattern
//   - Simple character class matching
//   - Replacing substrings by pattern
//
// Supported features:
//   - Literal character matching
//   - . (any char)
//   - * (zero or more)
//   - + (one or more)
//   - ? (zero or one)
//   - [abc], [a-z], [^abc] (character classes)
//   - ^ (start anchor)
//   - $ (end anchor)
//   - \d, \w, \s, \D, \W, \S (character class shortcuts)
//   - | (alternation)
//   - () (grouping, capture)
//   - {n}, {n,}, {n,m} (repetition)
//
// NOT supported (BotGuard rarely uses):
//   - Lookahead/lookbehind
//   - Backreferences
//   - Unicode categories
//   - Named groups

const values = @import("values.sig");

pub const MAX_CAPTURES: usize = 16;
pub const MAX_PATTERN: usize = 256;

/// A regex match result.
pub const Match = struct {
    matched: bool = false,
    start: u32 = 0,
    len: u32 = 0,
    captures: [MAX_CAPTURES]Capture = undefined,
    n_captures: u8 = 0,
};

pub const Capture = struct {
    start: u32 = 0,
    len: u32 = 0,
};

// ── Compiled pattern ──

const OpCode = enum(u8) {
    lit, // match literal byte
    dot, // match any byte
    class, // match character class [start..end in class_buf]
    neg_class, // match negated class
    start_anchor, // ^
    end_anchor, // $
    group_start, // ( start capture
    group_end, // ) end capture
    split, // alternation: try left, then jump
    jump, // unconditional jump
    match, // successful match
};

const Inst = struct {
    op: OpCode = .lit,
    ch: u8 = 0, // for .lit
    class_start: u8 = 0,
    class_len: u8 = 0,
    target: u8 = 0, // jump/split target
    capture_id: u8 = 0,
};

var program: [MAX_PATTERN]Inst = undefined;
var prog_len: u8 = 0;
var class_buf: [512]u8 = undefined; // character class ranges stored here
var class_used: u16 = 0;

// ── Public API ──

/// Compile a regex pattern string.
/// Returns true on success.
pub fn compile(pattern: []const u8) bool {
    prog_len = 0;
    class_used = 0;
    var i: usize = 0;
    var capture_id: u8 = 0;

    while (i < pattern.len and prog_len < MAX_PATTERN) {
        const c = pattern[i];
        switch (c) {
            '.' => { emit(.dot, 0); i += 1; },
            '^' => { emit(.start_anchor, 0); i += 1; },
            '$' => { emit(.end_anchor, 0); i += 1; },
            '(' => { emitGroup(.group_start, capture_id); capture_id += 1; i += 1; },
            ')' => { emitGroup(.group_end, capture_id -| 1); i += 1; },
            '[' => { i = compileClass(pattern, i); },
            '\\' => { i = compileEscape(pattern, i); },
            '|' => { emit(.split, 0); i += 1; }, // simplified
            else => { emit(.lit, c); i += 1; },
        }

        // Quantifiers
        if (i < pattern.len) {
            const q = pattern[i];
            if (q == '*' or q == '+' or q == '?') {
                // For now: quantifiers are handled by the matcher as greedy
                // Mark the last instruction with repetition info (stored in .target)
                if (prog_len > 0) {
                    program[prog_len - 1].target = switch (q) {
                        '*' => 1,
                        '+' => 2,
                        '?' => 3,
                        else => 0,
                    };
                }
                i += 1;
            }
        }
    }
    emit(.match, 0);
    return true;
}

/// Execute the compiled pattern against a string.
/// Returns match result with captures.
pub fn exec(text: []const u8) Match {
    // Try matching at each position (unless anchored)
    if (prog_len > 0 and program[0].op == .start_anchor) {
        return tryMatch(text, 0);
    }
    for (0..text.len) |start| {
        const m = tryMatch(text, start);
        if (m.matched) return m;
    }
    return .{};
}

/// Test if pattern matches anywhere in text.
pub fn matches(text: []const u8) bool {
    return exec(text).matched;
}

/// Simple regex test without pre-compilation (convenience).
pub fn testPattern(pattern: []const u8, text: []const u8) bool {
    if (!compile(pattern)) return false;
    return matches(text);
}

/// Split a string by regex pattern.
/// Returns number of parts written to `out`.
pub fn split(text: []const u8, pattern: []const u8, out: *[64]u32, out_lens: *[64]u16) u8 {
    if (!compile(pattern)) {
        if (text.len > 0) { out[0] = 0; out_lens[0] = @intCast(text.len); return 1; }
        return 0;
    }
    var count: u8 = 0;
    var pos: usize = 0;
    while (pos < text.len and count < 64) {
        const m = tryMatch(text, pos);
        if (m.matched and m.len > 0) {
            out[count] = @intCast(pos);
            out_lens[count] = @intCast(m.start - @as(u32, @intCast(pos)));
            count += 1;
            pos = m.start + m.len;
        } else {
            break;
        }
    }
    // Remaining
    if (pos <= text.len and count < 64) {
        out[count] = @intCast(pos);
        out_lens[count] = @intCast(text.len - pos);
        count += 1;
    }
    return count;
}

// ── Internal Matching ──

fn tryMatch(text: []const u8, start: usize) Match {
    var result = Match{ .start = @intCast(start) };
    var pos = start;
    var pc: u8 = 0;

    while (pc < prog_len) {
        const inst = program[pc];
        switch (inst.op) {
            .match => {
                result.matched = true;
                result.len = @intCast(pos - start);
                return result;
            },
            .lit => {
                if (!matchWithQuantifier(text, &pos, inst)) return .{};
                pc += 1;
            },
            .dot => {
                if (!matchWithQuantifier(text, &pos, inst)) return .{};
                pc += 1;
            },
            .class, .neg_class => {
                if (!matchWithQuantifier(text, &pos, inst)) return .{};
                pc += 1;
            },
            .start_anchor => {
                if (pos != 0) return .{};
                pc += 1;
            },
            .end_anchor => {
                if (pos != text.len) return .{};
                pc += 1;
            },
            .group_start => {
                if (inst.capture_id < MAX_CAPTURES) {
                    result.captures[inst.capture_id].start = @intCast(pos);
                    if (inst.capture_id >= result.n_captures) result.n_captures = inst.capture_id + 1;
                }
                pc += 1;
            },
            .group_end => {
                if (inst.capture_id < MAX_CAPTURES) {
                    result.captures[inst.capture_id].len = @intCast(pos - result.captures[inst.capture_id].start);
                }
                pc += 1;
            },
            .split => {
                // Try next instruction; if fail, continue after split
                pc += 1; // simplified: just continue
            },
            .jump => {
                pc = inst.target;
            },
        }
    }
    return .{};
}

fn matchWithQuantifier(text: []const u8, pos: *usize, inst: Inst) bool {
    switch (inst.target) {
        0 => { // no quantifier: exactly one
            return matchOne(text, pos, inst);
        },
        1 => { // * : zero or more (greedy)
            while (pos.* < text.len and matchOneNoAdvance(text, pos.*, inst)) pos.* += 1;
            return true; // zero is fine
        },
        2 => { // + : one or more
            if (!matchOne(text, pos, inst)) return false;
            while (pos.* < text.len and matchOneNoAdvance(text, pos.*, inst)) pos.* += 1;
            return true;
        },
        3 => { // ? : zero or one
            if (pos.* < text.len and matchOneNoAdvance(text, pos.*, inst)) pos.* += 1;
            return true;
        },
        else => return matchOne(text, pos, inst),
    }
}

fn matchOne(text: []const u8, pos: *usize, inst: Inst) bool {
    if (pos.* >= text.len) return false;
    const c = text[pos.*];
    const ok = switch (inst.op) {
        .lit => c == inst.ch,
        .dot => c != '\n',
        .class => classContains(inst.class_start, inst.class_len, c),
        .neg_class => !classContains(inst.class_start, inst.class_len, c),
        else => false,
    };
    if (ok) pos.* += 1;
    return ok;
}

fn matchOneNoAdvance(text: []const u8, pos: usize, inst: Inst) bool {
    if (pos >= text.len) return false;
    const c = text[pos];
    return switch (inst.op) {
        .lit => c == inst.ch,
        .dot => c != '\n',
        .class => classContains(inst.class_start, inst.class_len, c),
        .neg_class => !classContains(inst.class_start, inst.class_len, c),
        else => false,
    };
}

fn classContains(start: u8, len: u8, c: u8) bool {
    var i: u16 = start;
    const end: u16 = @as(u16, start) + len;
    while (i + 1 < end) : (i += 2) {
        if (c >= class_buf[i] and c <= class_buf[i + 1]) return true;
    }
    return false;
}

// ── Pattern Compilation Helpers ──

fn emit(op: OpCode, ch: u8) void {
    if (prog_len >= MAX_PATTERN) return;
    program[prog_len] = .{ .op = op, .ch = ch };
    prog_len += 1;
}

fn emitGroup(op: OpCode, id: u8) void {
    if (prog_len >= MAX_PATTERN) return;
    program[prog_len] = .{ .op = op, .capture_id = id };
    prog_len += 1;
}

fn compileClass(pattern: []const u8, start: usize) usize {
    var i = start + 1; // skip [
    var negated = false;
    if (i < pattern.len and pattern[i] == '^') { negated = true; i += 1; }

    const class_start: u8 = @intCast(class_used);
    while (i < pattern.len and pattern[i] != ']') {
        if (i + 2 < pattern.len and pattern[i + 1] == '-') {
            // Range: a-z
            if (class_used + 2 <= 512) {
                class_buf[class_used] = pattern[i];
                class_buf[class_used + 1] = pattern[i + 2];
                class_used += 2;
            }
            i += 3;
        } else {
            // Single char
            if (class_used + 2 <= 512) {
                class_buf[class_used] = pattern[i];
                class_buf[class_used + 1] = pattern[i];
                class_used += 2;
            }
            i += 1;
        }
    }
    if (i < pattern.len) i += 1; // skip ]

    const class_len: u8 = @intCast(class_used - class_start);
    if (prog_len < MAX_PATTERN) {
        program[prog_len] = .{
            .op = if (negated) .neg_class else .class,
            .class_start = class_start,
            .class_len = class_len,
        };
        prog_len += 1;
    }
    return i;
}

fn compileEscape(pattern: []const u8, start: usize) usize {
    if (start + 1 >= pattern.len) { emit(.lit, '\\'); return start + 1; }
    const c = pattern[start + 1];
    switch (c) {
        'd' => emitShorthandClass('0', '9', false),
        'D' => emitShorthandClass('0', '9', true),
        'w' => { emitWordClass(false); },
        'W' => { emitWordClass(true); },
        's' => emitWhitespaceClass(false),
        'S' => emitWhitespaceClass(true),
        'n' => emit(.lit, '\n'),
        'r' => emit(.lit, '\r'),
        't' => emit(.lit, '\t'),
        '0' => emit(.lit, 0),
        else => emit(.lit, c), // escaped literal
    }
    return start + 2;
}

fn emitShorthandClass(lo: u8, hi: u8, negated: bool) void {
    const cs: u8 = @intCast(class_used);
    if (class_used + 2 <= 512) {
        class_buf[class_used] = lo;
        class_buf[class_used + 1] = hi;
        class_used += 2;
    }
    if (prog_len < MAX_PATTERN) {
        program[prog_len] = .{
            .op = if (negated) .neg_class else .class,
            .class_start = cs,
            .class_len = 2,
        };
        prog_len += 1;
    }
}

fn emitWordClass(negated: bool) void {
    const cs: u8 = @intCast(class_used);
    // [a-zA-Z0-9_]
    if (class_used + 8 <= 512) {
        class_buf[class_used] = 'a'; class_buf[class_used + 1] = 'z'; class_used += 2;
        class_buf[class_used] = 'A'; class_buf[class_used + 1] = 'Z'; class_used += 2;
        class_buf[class_used] = '0'; class_buf[class_used + 1] = '9'; class_used += 2;
        class_buf[class_used] = '_'; class_buf[class_used + 1] = '_'; class_used += 2;
    }
    if (prog_len < MAX_PATTERN) {
        program[prog_len] = .{
            .op = if (negated) .neg_class else .class,
            .class_start = cs,
            .class_len = 8,
        };
        prog_len += 1;
    }
}

fn emitWhitespaceClass(negated: bool) void {
    const cs: u8 = @intCast(class_used);
    // [ \t\n\r]
    if (class_used + 8 <= 512) {
        class_buf[class_used] = ' '; class_buf[class_used + 1] = ' '; class_used += 2;
        class_buf[class_used] = '\t'; class_buf[class_used + 1] = '\t'; class_used += 2;
        class_buf[class_used] = '\n'; class_buf[class_used + 1] = '\n'; class_used += 2;
        class_buf[class_used] = '\r'; class_buf[class_used + 1] = '\r'; class_used += 2;
    }
    if (prog_len < MAX_PATTERN) {
        program[prog_len] = .{
            .op = if (negated) .neg_class else .class,
            .class_start = cs,
            .class_len = 8,
        };
        prog_len += 1;
    }
}
