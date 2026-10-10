// Bounded, allocator-free regex engine for the VM's byte strings.
// Supports ASCII classes, captures, alternatives, greedy/lazy repetition and
// g/i/m/s/y. Unsupported syntax fails compilation; no partial pattern matching.
pub const MAX_CAPTURES: usize = 16;
pub const MAX_PATTERN: usize = 1024;
const MAX_CODE = 4096;
const NONE: u16 = 0xFFFF;
pub const Flags = struct { global: bool = false, ignore_case: bool = false, multiline: bool = false, dot_all: bool = false, sticky: bool = false };
pub const Capture = struct { start: u32 = 0, len: u32 = 0, matched: bool = false };
pub const Match = struct { matched: bool = false, exhausted: bool = false, start: u32 = 0, len: u32 = 0, captures: [MAX_CAPTURES]Capture = [_]Capture{.{}} ** MAX_CAPTURES, n_captures: u8 = 0 };
const Kind = enum { empty, literal, dot, class, start, end, boundary, nonboundary, sequence, alternate, capture, repeat };
const Node = struct { kind: Kind, left: u16 = NONE, right: u16 = NONE, value: u16 = 0, min: u16 = 0, max: u16 = 0, lazy: bool = false };
const Op = enum { literal, dot, class, start, end, boundary, nonboundary, save, clear_captures, split, jump, accept };
const Inst = struct { op: Op, value: u16 = 0, x: u16 = 0, y: u16 = 0, loop_id: u8 = 0xFF };
const Thread = struct { pc: u16 = 0, pos: u32 = 0, captures: [MAX_CAPTURES * 2]u32 = [_]u32{0xFFFFFFFF} ** (MAX_CAPTURES * 2), loops: [32]u32 = [_]u32{0xFFFFFFFF} ** 32 };
var nodes: [MAX_PATTERN]Node = undefined;
var node_count: u16 = 0;
var classes: [128][32]u8 = undefined;
var class_negated: [128]bool = undefined;
var class_count: u16 = 0;
var code: [MAX_CODE]Inst = undefined;
var code_count: u16 = 0;
var captures: u8 = 0;
var loops: u8 = 0;
var input: []const u8 = "";
var cursor: usize = 0;
var failed = false;
var options: Flags = .{};

pub fn parseFlags(text: []const u8) ?Flags {
    var flags = Flags{}; var seen: u16 = 0;
    for (text) |c| {
        const bit: u16 = switch (c) { 'g' => 1, 'i' => 2, 'm' => 4, 's' => 8, 'y' => 16, else => return null };
        if (seen & bit != 0) return null;
        seen |= bit;
        switch (c) { 'g' => flags.global = true, 'i' => flags.ignore_case = true, 'm' => flags.multiline = true, 's' => flags.dot_all = true, 'y' => flags.sticky = true, else => unreachable }
    }
    return flags;
}
pub fn compile(pattern: []const u8) bool { return compileFlags(pattern, .{}); }
pub fn compileFlags(pattern: []const u8, flags: Flags) bool {
    node_count = 0; class_count = 0; code_count = 0; captures = 0; loops = 0;
    input = pattern; cursor = 0; failed = pattern.len > MAX_PATTERN; options = flags;
    const root = parseAlternate(0);
    if (cursor != input.len) failed = true;
    if (!failed) compileNode(root, 0);
    _ = emit(.{ .op = .accept });
    return !failed;
}
pub fn exec(text: []const u8) Match { return execFrom(text, 0); }
pub fn execFrom(text: []const u8, offset: usize) Match {
    if (failed or offset > text.len) return .{};
    var start = offset; var budget: usize = 4 * 1024 * 1024;
    while (start <= text.len) : (start += 1) {
        const result = matchAt(text, start, &budget);
        if (result.matched or result.exhausted) return result;
        if (options.sticky) break;
    }
    return .{};
}
pub fn matches(text: []const u8) bool { return exec(text).matched; }
pub fn testPattern(pattern: []const u8, text: []const u8) bool { return compile(pattern) and matches(text); }
fn newNode(node: Node) u16 {
    if (node_count >= nodes.len) { failed = true; return 0; }
    const id = node_count; nodes[id] = node; node_count += 1; return id;
}
fn parseAlternate(depth: u16) u16 {
    if (depth > 64) { failed = true; return newNode(.{ .kind = .empty }); }
    var left = parseSequence(depth + 1);
    while (cursor < input.len and input[cursor] == '|') {
        cursor += 1; const right = parseSequence(depth + 1);
        left = newNode(.{ .kind = .alternate, .left = left, .right = right });
    }
    return left;
}
fn parseSequence(depth: u16) u16 {
    var left = newNode(.{ .kind = .empty });
    while (cursor < input.len and input[cursor] != ')' and input[cursor] != '|' and !failed) {
        const right = parseRepeated(depth + 1);
        left = newNode(.{ .kind = .sequence, .left = left, .right = right });
    }
    return left;
}
fn parseRepeated(depth: u16) u16 {
    const atom = parseAtom(depth + 1);
    if (cursor == input.len) return atom;
    var min: u16 = 0; var max: u16 = 0;
    switch (input[cursor]) {
        '*' => { min = 0; max = NONE; cursor += 1; },
        '+' => { min = 1; max = NONE; cursor += 1; },
        '?' => { min = 0; max = 1; cursor += 1; },
        '{' => {
            cursor += 1; min = parseInteger(); max = min;
            if (cursor < input.len and input[cursor] == ',') {
                cursor += 1; max = if (cursor < input.len and input[cursor] == '}') NONE else parseInteger();
            }
            if (cursor == input.len or input[cursor] != '}' or max < min) { failed = true; return atom; }
            cursor += 1;
        },
        else => return atom,
    }
    var lazy = false;
    if (cursor < input.len and input[cursor] == '?') { lazy = true; cursor += 1; }
    return newNode(.{ .kind = .repeat, .left = atom, .min = min, .max = max, .lazy = lazy });
}
fn parseInteger() u16 {
    var n: u16 = 0; const before = cursor;
    while (cursor < input.len and input[cursor] >= '0' and input[cursor] <= '9') {
        if (n > 400) { failed = true; return 0; }
        n = n * 10 + input[cursor] - '0'; cursor += 1;
    }
    if (before == cursor or n > 1024) failed = true;
    return n;
}
fn parseAtom(depth: u16) u16 {
    if (depth > 64 or cursor >= input.len) { failed = true; return newNode(.{ .kind = .empty }); }
    const c = input[cursor]; cursor += 1;
    switch (c) {
        '.' => return newNode(.{ .kind = .dot }),
        '^' => return newNode(.{ .kind = .start }),
        '$' => return newNode(.{ .kind = .end }),
        '(' => {
            var capture = true;
            if (cursor < input.len and input[cursor] == '?') {
                cursor += 1;
                if (cursor == input.len or input[cursor] != ':') { failed = true; return newNode(.{ .kind = .empty }); }
                cursor += 1; capture = false;
            }
            const id = captures;
            if (capture) { if (captures == MAX_CAPTURES) failed = true else captures += 1; }
            const child = parseAlternate(depth + 1);
            if (cursor == input.len or input[cursor] != ')') failed = true else cursor += 1;
            return if (capture) newNode(.{ .kind = .capture, .left = child, .value = id }) else child;
        },
        '[' => return parseClass(),
        '\\' => {
            if (cursor == input.len) { failed = true; return newNode(.{ .kind = .empty }); }
            const e = input[cursor]; cursor += 1;
            if (e == 'b' or e == 'B') return newNode(.{ .kind = if (e == 'b') .boundary else .nonboundary });
            if (e >= '1' and e <= '9') { failed = true; return newNode(.{ .kind = .empty }); }
            if (isShorthand(e)) {
                const id = allocClass(); addShorthand(id, e);
                return newNode(.{ .kind = .class, .value = id });
            }
            return newNode(.{ .kind = .literal, .value = escapedByte(e) });
        },
        '*', '+', '?', ')' => { failed = true; return newNode(.{ .kind = .empty }); },
        else => return newNode(.{ .kind = .literal, .value = c }),
    }
}
fn escapedByte(c: u8) u8 {
    switch (c) {
        'n' => return '\n', 'r' => return '\r', 't' => return '\t', 'f' => return 12, 'v' => return 11, '0' => return 0,
        'x', 'u' => {
            const digits: usize = if (c == 'x') 2 else 4;
            if (cursor + digits > input.len) { failed = true; return 0; }
            var n: u16 = 0;
            for (input[cursor..][0..digits]) |b| {
                const v: u16 = if (b >= '0' and b <= '9') b - '0' else if (b >= 'a' and b <= 'f') b - 'a' + 10 else if (b >= 'A' and b <= 'F') b - 'A' + 10 else blk: { failed = true; break :blk 0; };
                n = n * 16 + v;
            }
            cursor += digits;
            if (n > 255) failed = true;
            return @truncate(n);
        },
        else => return c,
    }
}
fn allocClass() u16 {
    if (class_count == classes.len) { failed = true; return 0; }
    const id = class_count; classes[id] = [_]u8{0} ** 32; class_negated[id] = false; class_count += 1; return id;
}
fn classAdd(id: u16, c: u8) void { classes[id][c / 8] |= @as(u8, 1) << @intCast(c % 8); }
fn isShorthand(c: u8) bool { return c == 'd' or c == 'D' or c == 'w' or c == 'W' or c == 's' or c == 'S'; }
fn isWord(c: u8) bool { return c >= 'a' and c <= 'z' or c >= 'A' and c <= 'Z' or c >= '0' and c <= '9' or c == '_'; }
fn addShorthand(id: u16, shorthand: u8) void {
    for (0..256) |n| {
        const c: u8 = @intCast(n);
        const base = switch (shorthand) { 'd', 'D' => c >= '0' and c <= '9', 'w', 'W' => isWord(c), else => c == ' ' or c >= 9 and c <= 13 };
        if (base != (shorthand == 'D' or shorthand == 'W' or shorthand == 'S')) classAdd(id, c);
    }
}
fn classByte() ?u8 {
    if (cursor == input.len) { failed = true; return 0; }
    const c = input[cursor]; cursor += 1;
    if (c != '\\') return c;
    if (cursor == input.len) { failed = true; return 0; }
    const e = input[cursor]; cursor += 1;
    if (isShorthand(e)) return null;
    return if (e == 'b') 8 else escapedByte(e);
}
fn parseClass() u16 {
    const id = allocClass(); var negate = false;
    if (cursor < input.len and input[cursor] == '^') { negate = true; cursor += 1; }
    while (cursor < input.len and input[cursor] != ']' and !failed) {
        const start = classByte();
        if (start) |a| {
            if (cursor + 1 < input.len and input[cursor] == '-' and input[cursor + 1] != ']') {
                cursor += 1;
                const b = classByte() orelse { failed = true; break; };
                if (b < a) { failed = true; break; }
                var c: u16 = a; while (c <= b) : (c += 1) classAdd(id, @intCast(c));
            } else classAdd(id, a);
        } else addShorthand(id, input[cursor - 1]);
    }
    if (cursor == input.len) failed = true else cursor += 1;
    class_negated[id] = negate;
    return newNode(.{ .kind = .class, .value = id });
}
fn emit(inst: Inst) u16 {
    if (code_count >= code.len) { failed = true; return 0; }
    const at = code_count; code[at] = inst; code_count += 1; return at;
}
fn compileNode(id: u16, depth: u16) void {
    if (failed or depth > MAX_PATTERN) { failed = true; return; }
    const node = nodes[id];
    switch (node.kind) {
        .empty => {},
        .literal => { _ = emit(.{ .op = .literal, .value = node.value }); },
        .dot => { _ = emit(.{ .op = .dot }); },
        .class => { _ = emit(.{ .op = .class, .value = node.value }); },
        .start => { _ = emit(.{ .op = .start }); },
        .end => { _ = emit(.{ .op = .end }); },
        .boundary => { _ = emit(.{ .op = .boundary }); },
        .nonboundary => { _ = emit(.{ .op = .nonboundary }); },
        .sequence => { compileNode(node.left, depth + 1); compileNode(node.right, depth + 1); },
        .alternate => {
            const branch = emit(.{ .op = .split }); code[branch].x = code_count;
            compileNode(node.left, depth + 1); const skip = emit(.{ .op = .jump });
            code[branch].y = code_count; compileNode(node.right, depth + 1); code[skip].x = code_count;
        },
        .capture => {
            _ = emit(.{ .op = .save, .value = node.value * 2 }); compileNode(node.left, depth + 1);
            _ = emit(.{ .op = .save, .value = node.value * 2 + 1 });
        },
        .repeat => {
            for (0..node.min) |_| compileRepeatedAtom(node.left, depth + 1);
            if (node.max == NONE) {
                if (loops == 32) { failed = true; return; }
                const loop_id = loops; loops += 1;
                const branch = emit(.{ .op = .split, .loop_id = loop_id }); const body = code_count;
                compileRepeatedAtom(node.left, depth + 1); _ = emit(.{ .op = .jump, .x = branch });
                code[branch].x = if (node.lazy) code_count else body;
                code[branch].y = if (node.lazy) body else code_count;
            } else for (0..node.max - node.min) |_| {
                const branch = emit(.{ .op = .split }); const body = code_count;
                compileRepeatedAtom(node.left, depth + 1);
                code[branch].x = if (node.lazy) code_count else body;
                code[branch].y = if (node.lazy) body else code_count;
            }
        },
    }
}
fn captureMask(id: u16) u16 {
    const node = nodes[id];
    return switch (node.kind) {
        .capture => (@as(u16, 1) << @intCast(node.value)) | captureMask(node.left),
        .sequence, .alternate => captureMask(node.left) | captureMask(node.right),
        .repeat => captureMask(node.left),
        else => 0,
    };
}
fn compileRepeatedAtom(id: u16, depth: u16) void {
    const mask = captureMask(id);
    if (mask != 0) _ = emit(.{ .op = .clear_captures, .value = mask });
    compileNode(id, depth);
}
fn lineTerminator(c: u8) bool { return c == '\n' or c == '\r'; }
fn lower(c: u8) u8 { return if (c >= 'A' and c <= 'Z') c + 32 else c; }
fn classHas(id: u16, c: u8) bool { return classes[id][c / 8] & (@as(u8, 1) << @intCast(c % 8)) != 0; }
fn classMatches(id: u16, c: u8) bool {
    const present = classHas(id, c) or options.ignore_case and (classHas(id, lower(c)) or (c >= 'a' and c <= 'z' and classHas(id, c - 32)));
    return present != class_negated[id];
}
fn matchAt(text: []const u8, start: usize, budget: *usize) Match {
    var backtrack: [1024]Thread = undefined; var count: usize = 0;
    var thread = Thread{ .pos = @intCast(start) };
    while (true) {
        if (budget.* == 0) return .{ .exhausted = true };
        budget.* -= 1;
        const inst = code[thread.pc]; const pos = thread.pos; var success = true;
        switch (inst.op) {
            .accept => {
                var result = Match{ .matched = true, .start = @intCast(start), .len = @intCast(pos - start), .n_captures = captures };
                for (0..captures) |i| {
                    const a = thread.captures[i * 2]; const b = thread.captures[i * 2 + 1];
                    if (a != 0xFFFFFFFF and b != 0xFFFFFFFF and b >= a) result.captures[i] = .{ .start = a, .len = b - a, .matched = true };
                }
                return result;
            },
            .literal => { success = pos < text.len and (text[pos] == inst.value or options.ignore_case and lower(text[pos]) == lower(@intCast(inst.value))); if (success) thread.pos += 1; thread.pc += 1; },
            .dot => { success = pos < text.len and (options.dot_all or !lineTerminator(text[pos])); if (success) thread.pos += 1; thread.pc += 1; },
            .class => {
                success = pos < text.len and classMatches(inst.value, text[pos]);
                if (success) thread.pos += 1; thread.pc += 1;
            },
            .start => { success = pos == 0 or options.multiline and pos > 0 and lineTerminator(text[pos - 1]); thread.pc += 1; },
            .end => { success = pos == text.len or options.multiline and pos < text.len and lineTerminator(text[pos]); thread.pc += 1; },
            .boundary, .nonboundary => { const boundary = (pos > 0 and isWord(text[pos - 1])) != (pos < text.len and isWord(text[pos])); success = boundary == (inst.op == .boundary); thread.pc += 1; },
            .save => { thread.captures[inst.value] = pos; thread.pc += 1; },
            .clear_captures => {
                for (0..MAX_CAPTURES) |i| {
                    if (inst.value & (@as(u16, 1) << @intCast(i)) != 0) {
                        thread.captures[i * 2] = 0xFFFFFFFF; thread.captures[i * 2 + 1] = 0xFFFFFFFF;
                    }
                }
                thread.pc += 1;
            },
            .jump => thread.pc = inst.x,
            .split => {
                if (inst.loop_id != 0xFF and thread.loops[inst.loop_id] == pos) { thread.pc = @max(inst.x, inst.y); continue; }
                if (inst.loop_id != 0xFF) thread.loops[inst.loop_id] = pos;
                if (count == backtrack.len) return .{ .exhausted = true };
                backtrack[count] = thread; backtrack[count].pc = inst.y; count += 1; thread.pc = inst.x;
            },
        }
        if (!success) { if (count == 0) return .{}; count -= 1; thread = backtrack[count]; }
    }
}
pub fn split(text: []const u8, pattern: []const u8, out: *[64]u32, out_lens: *[64]u16) u8 {
    if (!compile(pattern)) return 0;
    var n: u8 = 0; var from: usize = 0; var scan: usize = 0;
    while (scan <= text.len and n < 63) {
        const m = execFrom(text, scan); if (!m.matched) break;
        if (m.len == 0 and m.start == from) { scan = m.start + 1; continue; }
        out[n] = @intCast(from); out_lens[n] = @intCast(@min(m.start - from, 65535)); n += 1;
        from = m.start + m.len; scan = from + @intFromBool(m.len == 0);
    }
    out[n] = @intCast(from); out_lens[n] = @intCast(@min(text.len - from, 65535)); return n + 1;
}
