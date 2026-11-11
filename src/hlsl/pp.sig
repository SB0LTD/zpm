//! @zpm/hlsl pp — HLSL's preprocessor (C's): object- and function-like
//! macros with `#` and `##`, `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/
//! `#endif` with `defined`, `#include` through the caller's include
//! interface (D3D_INCLUDE_LOCAL for "", SYSTEM for <>), `#undef`,
//! `#line`, `#error`, and `#pragma` (pack_matrix passed on to the parser,
//! the rest accepted and ignored, as fxc does with ones it does not know).
//! Defines given with the call (D3D_SHADER_MACRO) are object-like macros
//! made before the source is read.
//!
//! Allocation-free: tokens, macros and text live in the arrays the caller
//! hands over (the Compiler's).

const std = @import("std");
const lex = @import("lex.sig");
const Token = lex.Token;
const Kind = lex.Kind;

pub const MAX_MACROS = 4096;
pub const MAX_PARAMS = 32;
const MAX_STREAMS = 256;
const MAX_IF = 64;
const MAX_INCLUDE_DEPTH = 32;
pub const MAX_FILES = 250;

/// The caller's include handler: opens a file by name ("" is local, <> is
/// system) and gives its bytes, which stay valid until `close`.
pub const Include = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (ctx: ?*anyopaque, system: bool, name: []const u8, parent: ?[]const u8) ?[]const u8,
    close: *const fn (ctx: ?*anyopaque, data: []const u8) void,
};

pub const Define = struct { name: []const u8, value: []const u8 = "1" };

/// Messages, fxc-shaped: `file(line): error X0000: text`.
pub const Log = struct {
    buf: []u8,
    len: usize = 0,
    errors: u32 = 0,
    file_name: []const u8 = "",
    /// the column of the next message (1-based; 0: none), set by whoever
    /// knows the token
    col: u32 = 0,

    pub fn err(l: *Log, line: u32, comptime fmt: []const u8, args: anytype) void {
        l.errors += 1;
        l.put(line, "error", fmt, args);
    }

    pub fn warn(l: *Log, line: u32, comptime fmt: []const u8, args: anytype) void {
        l.put(line, "warning", fmt, args);
    }

    fn put(l: *Log, line: u32, what: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (l.len >= l.buf.len) return;
        const name = if (l.file_name.len > 0) l.file_name else "hlsl";
        const head = (if (l.col > 0)
            std.fmt.bufPrint(l.buf[l.len..], "{s}({d},{d}): {s} X3000: ", .{ name, line, l.col, what })
        else
            std.fmt.bufPrint(l.buf[l.len..], "{s}({d}): {s} X3000: ", .{ name, line, what })) catch {
            l.len = l.buf.len;
            return;
        };
        l.len += head.len;
        const body = std.fmt.bufPrint(l.buf[l.len..], fmt ++ "\n", args) catch {
            l.len = l.buf.len;
            return;
        };
        l.len += body.len;
    }

    pub fn text(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }
};

pub const Macro = struct {
    name_off: u32,
    name_len: u16,
    func: bool,
    variadic: bool = false,
    nparams: u8 = 0,
    params: [MAX_PARAMS]u32 = undefined,
    plens: [MAX_PARAMS]u16 = undefined,
    body: u32 = 0,
    body_len: u32 = 0,
    live: bool = true,
};

const Stream = struct { toks: []const Token, at: usize = 0, macro: u16 = NO_MACRO };
const NO_MACRO: u16 = 0xffff;

const Cond = struct { parent_on: bool, on: bool, taken: bool, seen_else: bool = false };

pub const Pp = struct {
    pool: []u8,
    pool_len: u32 = 0,
    raw: []Token,
    raw_len: usize = 0,
    out: []Token,
    out_len: usize = 0,
    mtoks: []Token,
    mtoks_len: usize = 0,
    scratch: []Token,
    scratch_len: usize = 0,
    /// expanded arguments and #if lines (a stack)
    xout: []Token,
    xout_len: usize = 0,
    macros: *[MAX_MACROS]Macro,
    nmacros: u32 = 0,
    streams: [MAX_STREAMS]Stream = undefined,
    nstreams: usize = 0,
    conds: [MAX_IF]Cond = undefined,
    ncond: usize = 0,
    include: ?Include = null,
    log: *Log,
    depth: u32 = 0,
    nfiles: u8 = 0,
    failed: bool = false,

    pub fn fail(p: *Pp, line: u32, comptime fmt: []const u8, args: anytype) void {
        p.log.col = 0;
        p.log.err(line, fmt, args);
        p.failed = true;
    }

    pub fn text(p: *const Pp, t: Token) []const u8 {
        return p.pool[t.off..][0..t.len];
    }

    /// Copies bytes into the pool; their offset.
    pub fn intern(p: *Pp, s: []const u8) ?u32 {
        if (p.pool_len + s.len + 1 > p.pool.len) {
            p.fail(0, "out of text space", .{});
            return null;
        }
        const at = p.pool_len;
        @memcpy(p.pool[at..][0..s.len], s);
        p.pool[at + s.len] = 0;
        p.pool_len += @intCast(s.len + 1);
        return at;
    }

    // ── Macros ──

    fn find(p: *const Pp, name: []const u8) ?u16 {
        var i = p.nmacros;
        while (i > 0) {
            i -= 1;
            const m = &p.macros[i];
            if (m.live and m.name_len == name.len and std.mem.eql(u8, p.pool[m.name_off..][0..m.name_len], name)) return @intCast(i);
        }
        return null;
    }

    fn undef(p: *Pp, name: []const u8) void {
        while (p.find(name)) |i| p.macros[i].live = false;
    }

    /// An object-like macro from text (the call's defines, predefined ones).
    pub fn defineText(p: *Pp, name: []const u8, value: []const u8) void {
        const no = p.intern(name) orelse return;
        const vo = p.intern(value) orelse return;
        p.undef(name);
        if (p.nmacros >= MAX_MACROS) return p.fail(0, "too many macros", .{});
        const room = p.mtoks[p.mtoks_len..];
        const n = lex.lex(p.pool[vo..][0..value.len], vo, 0, 0, room) orelse return p.fail(0, "macro too long", .{});
        // (drop the trailing newlines and eof)
        var len: usize = 0;
        for (room[0..n]) |t| {
            if (t.kind == .newline or t.kind == .eof) continue;
            room[len] = t;
            len += 1;
        }
        p.macros[p.nmacros] = .{ .name_off = no, .name_len = @intCast(name.len), .func = false, .body = @intCast(p.mtoks_len), .body_len = @intCast(len) };
        p.mtoks_len += len;
        p.nmacros += 1;
    }

    fn defineDirective(p: *Pp, line: []const Token) void {
        if (line.len == 0 or line[0].kind != .ident) return p.fail(lineOf(line), "#define needs a name", .{});
        const name = line[0];
        var m = Macro{ .name_off = name.off, .name_len = name.len, .func = false };
        var i: usize = 1;
        // a function-like macro: '(' right after the name, no space
        if (i < line.len and line[i].kind == .lparen and line[i].flags & lex.SPACE == 0) {
            m.func = true;
            i += 1;
            while (i < line.len and line[i].kind != .rparen) {
                const t = line[i];
                if (t.kind == .ident) {
                    if (m.nparams >= MAX_PARAMS) return p.fail(t.line(), "too many macro parameters", .{});
                    m.params[m.nparams] = t.off;
                    m.plens[m.nparams] = t.len;
                    m.nparams += 1;
                } else if (t.kind == .dot) {
                    // "..." (three dots)
                    m.variadic = true;
                    if (m.nparams >= MAX_PARAMS) return p.fail(t.line(), "too many macro parameters", .{});
                    const va = p.intern("__VA_ARGS__") orelse return;
                    m.params[m.nparams] = va;
                    m.plens[m.nparams] = 11;
                    m.nparams += 1;
                    while (i + 1 < line.len and line[i + 1].kind == .dot) i += 1;
                } else if (t.kind != .comma) return p.fail(t.line(), "bad macro parameter list", .{});
                i += 1;
            }
            if (i >= line.len) return p.fail(lineOf(line), "unterminated macro parameter list", .{});
            i += 1;
        }
        const body = line[i..];
        if (p.mtoks_len + body.len > p.mtoks.len) return p.fail(lineOf(line), "out of macro space", .{});
        @memcpy(p.mtoks[p.mtoks_len..][0..body.len], body);
        if (body.len > 0) p.mtoks[p.mtoks_len].flags &= ~lex.SPACE;
        m.body = @intCast(p.mtoks_len);
        m.body_len = @intCast(body.len);
        p.mtoks_len += body.len;
        p.undef(p.text(name));
        if (p.nmacros >= MAX_MACROS) return p.fail(name.line(), "too many macros", .{});
        p.macros[p.nmacros] = m;
        p.nmacros += 1;
    }

    fn paramIndex(p: *const Pp, m: *const Macro, t: Token) ?usize {
        if (t.kind != .ident) return null;
        const s = p.text(t);
        for (0..m.nparams) |k| {
            if (m.plens[k] == s.len and std.mem.eql(u8, p.pool[m.params[k]..][0..m.plens[k]], s)) return k;
        }
        return null;
    }

    // ── Files ──

    /// Preprocesses `src` (named `name`) into `out`; false on an error.
    pub fn run(p: *Pp, src: []const u8, name: []const u8) bool {
        p.log.file_name = name;
        const at = p.intern(src) orelse return false;
        p.processText(at, @intCast(src.len));
        if (p.ncond != 0 and !p.failed) p.fail(0, "unterminated #if", .{});
        if (p.out_len >= p.out.len) {
            p.fail(0, "shader too long", .{});
            return false;
        }
        p.out[p.out_len] = .{ .kind = .eof, .off = p.pool_len };
        return !p.failed;
    }

    fn processText(p: *Pp, at: u32, len: u32) void {
        if (p.depth >= MAX_INCLUDE_DEPTH) return p.fail(0, "#include nested too deep", .{});
        const file = p.nfiles;
        if (p.nfiles < MAX_FILES) p.nfiles += 1;
        const base = p.raw_len;
        const n = lex.lex(p.pool[at..][0..len], at, file, 1, p.raw[base..]) orelse return p.fail(0, "shader too long", .{});
        p.raw_len += n;
        defer p.raw_len = base;
        p.depth += 1;
        defer p.depth -= 1;
        const toks = p.raw[base..][0..n];
        const cond_base = p.ncond;
        var i: usize = 0;
        while (i < toks.len and !p.failed) {
            const t = toks[i];
            if (t.kind == .eof) break;
            if (t.kind == .hash and t.flags & lex.BOL != 0) {
                var e = i + 1;
                while (toks[e].kind != .newline and toks[e].kind != .eof) e += 1;
                p.directive(toks[i + 1 .. e]);
                i = e + 1;
                continue;
            }
            if (!p.on()) {
                while (toks[i].kind != .newline and toks[i].kind != .eof) i += 1;
                i += 1;
                continue;
            }
            // a run of text lines, up to the next directive
            var e = i;
            while (toks[e].kind != .eof and !(toks[e].kind == .hash and toks[e].flags & lex.BOL != 0)) e += 1;
            p.expandRun(toks[i..e]);
            i = e;
        }
        if (p.ncond > cond_base and !p.failed) p.fail(0, "unterminated #if in an included file", .{});
    }

    fn on(p: *const Pp) bool {
        return p.ncond == 0 or p.conds[p.ncond - 1].on;
    }

    fn directive(p: *Pp, line: []const Token) void {
        if (line.len == 0) return; // (the null directive)
        const d = p.text(line[0]);
        const rest = line[1..];
        const ln = line[0].line();
        // conditionals are followed even when skipping
        if (eq(d, "if") or eq(d, "ifdef") or eq(d, "ifndef")) {
            if (p.ncond >= MAX_IF) return p.fail(ln, "#if nested too deep", .{});
            const parent = p.on();
            var v = false;
            if (parent) {
                if (eq(d, "if")) v = p.evalIf(rest) else {
                    if (rest.len == 0 or rest[0].kind != .ident) return p.fail(ln, "#{s} needs a name", .{d});
                    v = p.find(p.text(rest[0])) != null;
                    if (eq(d, "ifndef")) v = !v;
                }
            }
            p.conds[p.ncond] = .{ .parent_on = parent, .on = parent and v, .taken = parent and v };
            p.ncond += 1;
            return;
        }
        if (eq(d, "elif")) {
            if (p.ncond == 0) return p.fail(ln, "#elif without #if", .{});
            const c = &p.conds[p.ncond - 1];
            if (c.seen_else) return p.fail(ln, "#elif after #else", .{});
            if (c.taken or !c.parent_on) {
                c.on = false;
            } else {
                const v = p.evalIf(rest);
                c.on = v;
                c.taken = v;
            }
            return;
        }
        if (eq(d, "else")) {
            if (p.ncond == 0) return p.fail(ln, "#else without #if", .{});
            const c = &p.conds[p.ncond - 1];
            if (c.seen_else) return p.fail(ln, "#else after #else", .{});
            c.seen_else = true;
            c.on = c.parent_on and !c.taken;
            c.taken = true;
            return;
        }
        if (eq(d, "endif")) {
            if (p.ncond == 0) return p.fail(ln, "#endif without #if", .{});
            p.ncond -= 1;
            return;
        }
        if (!p.on()) return;
        if (eq(d, "define")) return p.defineDirective(rest);
        if (eq(d, "undef")) {
            if (rest.len == 0 or rest[0].kind != .ident) return p.fail(ln, "#undef needs a name", .{});
            return p.undef(p.text(rest[0]));
        }
        if (eq(d, "include")) return p.includeDirective(rest, ln);
        if (eq(d, "pragma")) {
            // pack_matrix(row_major | column_major): the parser's
            if (rest.len >= 4 and eq(p.text(rest[0]), "pack_matrix")) {
                const which = p.text(rest[2]);
                const k: Kind = if (eq(which, "row_major")) .pragma_row_major else if (eq(which, "column_major")) .pragma_column_major else return;
                p.emit(.{ .kind = k, .off = rest[0].off, .pos = rest[0].pos });
            }
            return;
        }
        if (eq(d, "line")) return; // (lines are kept as the source has them)
        if (eq(d, "error")) {
            const a = if (rest.len > 0) rest[0].off else line[0].off;
            const b = if (rest.len > 0) rest[rest.len - 1].off + rest[rest.len - 1].len else a;
            return p.fail(ln, "#error {s}", .{p.pool[a..b]});
        }
        if (eq(d, "warning") or eq(d, "message")) return;
        return p.fail(ln, "unknown directive #{s}", .{d});
    }

    fn includeDirective(p: *Pp, rest: []const Token, ln: u32) void {
        // (a macro naming the file is expanded first)
        var name: []const u8 = "";
        var system = false;
        if (rest.len > 0 and rest[0].kind == .string) {
            const s = p.text(rest[0]);
            name = s[1 .. s.len - 1];
        } else if (rest.len > 0 and rest[0].kind == .lt) {
            const a = rest[0].off + 1;
            var e: usize = 1;
            while (e < rest.len and rest[e].kind != .gt) e += 1;
            if (e >= rest.len) return p.fail(ln, "#include <...> not closed", .{});
            name = p.pool[a..rest[e].off];
            system = true;
        } else return p.fail(ln, "#include needs a file name", .{});
        const inc = p.include orelse return p.fail(ln, "#include \"{s}\": no include handler", .{name});
        const data = inc.open(inc.ctx, system, name, null) orelse return p.fail(ln, "failed to open source file: '{s}'", .{name});
        const at = p.intern(data);
        inc.close(inc.ctx, data);
        const a = at orelse return;
        p.processText(a, @intCast(data.len));
    }

    // ── Expansion ──

    fn emit(p: *Pp, t: Token) void {
        if (p.out_len >= p.out.len) {
            if (!p.failed) p.fail(t.line(), "shader too long", .{});
            return;
        }
        p.out[p.out_len] = t;
        p.out_len += 1;
    }

    fn push(p: *Pp, toks: []const Token, macro: u16) bool {
        if (p.nstreams >= MAX_STREAMS) {
            p.fail(if (toks.len > 0) toks[0].line() else 0, "macros nested too deep", .{});
            return false;
        }
        p.streams[p.nstreams] = .{ .toks = toks, .macro = macro };
        p.nstreams += 1;
        return true;
    }

    /// The next token above `floor` (null when they are spent); newlines
    /// skipped.
    fn next(p: *Pp, floor: usize) ?Token {
        while (p.nstreams > floor) {
            const s = &p.streams[p.nstreams - 1];
            if (s.at < s.toks.len) {
                const t = s.toks[s.at];
                s.at += 1;
                if (t.kind == .newline) continue;
                return t;
            }
            p.nstreams -= 1;
        }
        return null;
    }

    /// The next non-newline token above `floor`, not taken.
    fn peek(p: *Pp, floor: usize) ?Token {
        var k = p.nstreams;
        while (k > floor) {
            const s = &p.streams[k - 1];
            var at = s.at;
            while (at < s.toks.len) : (at += 1) {
                if (s.toks[at].kind != .newline) return s.toks[at];
            }
            k -= 1;
        }
        return null;
    }

    fn active(p: *const Pp, m: u16) bool {
        for (p.streams[0..p.nstreams]) |s| {
            if (s.macro == m and s.at <= s.toks.len) return true;
        }
        return false;
    }

    fn expandRun(p: *Pp, toks: []const Token) void {
        const mark = p.scratch_len;
        defer p.scratch_len = mark;
        if (!p.push(toks, NO_MACRO)) return;
        const floor = p.nstreams - 1;
        while (p.next(floor)) |t| {
            if (p.failed) return;
            p.expandOne(t, floor, .out);
        }
    }

    const Sink = enum { out, xout };

    fn put(p: *Pp, t: Token, sink: Sink) void {
        switch (sink) {
            .out => p.emit(t),
            .xout => {
                if (p.xout_len >= p.xout.len) {
                    if (!p.failed) p.fail(t.line(), "macro expansion too long", .{});
                    return;
                }
                p.xout[p.xout_len] = t;
                p.xout_len += 1;
            },
        }
    }

    /// Appends to the work arena (arguments' raw tokens, replacements).
    fn work(p: *Pp, t: Token) void {
        if (p.scratch_len >= p.scratch.len) {
            if (!p.failed) p.fail(t.line(), "macro expansion too long", .{});
            return;
        }
        p.scratch[p.scratch_len] = t;
        p.scratch_len += 1;
    }

    /// One token read above `floor`: a macro's name is expanded (its
    /// replacement pushed to be read on), anything else goes to `sink`.
    fn expandOne(p: *Pp, t0: Token, floor: usize, sink: Sink) void {
        var t = t0;
        if (t.kind != .ident or t.flags & lex.NOEXPAND != 0) return p.put(t, sink);
        const name = p.text(t);
        if (eq(name, "__LINE__")) {
            var b: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "{d}", .{t.line()}) catch "0";
            const o = p.intern(s) orelse return;
            return p.put(.{ .off = o, .len = @intCast(s.len), .kind = .int_lit, .pos = t.pos, .flags = t.flags }, sink);
        }
        const mi = p.find(name) orelse return p.put(t, sink);
        if (p.active(mi)) {
            t.flags |= lex.NOEXPAND;
            return p.put(t, sink);
        }
        const m = p.macros[mi];
        const body = p.mtoks[m.body..][0..m.body_len];
        if (!m.func) {
            if (body.len == 0) return;
            // (the expansion's first token takes the name's spacing)
            const start = p.scratch_len;
            for (body) |b| {
                var c = b;
                c.pos = t.pos;
                p.work(c);
            }
            if (p.scratch_len > start) p.scratch[start].flags = (p.scratch[start].flags & ~lex.SPACE) | (t.flags & lex.SPACE);
            p.pasteAll(start);
            _ = p.push(p.scratch[start..p.scratch_len], mi);
            return;
        }
        // function-like: only with '(' next
        const nx = p.peek(floor) orelse return p.put(t, sink);
        if (nx.kind != .lparen) return p.put(t, sink);
        _ = p.next(floor);
        // the arguments' raw tokens, into scratch
        var arg_start: [MAX_PARAMS + 1]usize = undefined;
        var nargs: usize = 0;
        const raw0 = p.scratch_len;
        arg_start[0] = raw0;
        var depth: u32 = 0;
        while (true) {
            const a = p.next(floor) orelse return p.fail(t.line(), "unterminated call of macro {s}", .{name});
            if (a.kind == .lparen) depth += 1;
            if (a.kind == .rparen) {
                if (depth == 0) break;
                depth -= 1;
            }
            if (a.kind == .comma and depth == 0 and !(m.variadic and nargs + 1 >= m.nparams)) {
                nargs += 1;
                if (nargs >= MAX_PARAMS) return p.fail(t.line(), "too many macro arguments", .{});
                arg_start[nargs] = p.scratch_len;
                continue;
            }
            p.work(a);
        }
        nargs += 1;
        arg_start[nargs] = p.scratch_len;
        if (nargs == 1 and m.nparams == 0 and arg_start[1] == arg_start[0]) nargs = 0;
        if (nargs != m.nparams and !(m.variadic and nargs + 1 == m.nparams)) {
            return p.fail(t.line(), "macro {s} takes {d} arguments, not {d}", .{ name, m.nparams, nargs });
        }
        if (nargs < m.nparams) {
            nargs += 1;
            arg_start[nargs] = arg_start[nargs - 1];
        }
        // each argument fully expanded (for uses not next to # or ##)
        var exp_start: [MAX_PARAMS + 1]usize = undefined;
        const xmark = p.xout_len;
        defer p.xout_len = xmark;
        for (0..nargs) |k| {
            exp_start[k] = p.xout_len;
            const arg = p.scratch[arg_start[k]..arg_start[k + 1]];
            if (!p.push(arg, NO_MACRO)) return;
            const f2 = p.nstreams - 1;
            while (p.next(f2)) |x| {
                if (p.failed) return;
                p.expandOne(x, f2, .xout);
            }
        }
        exp_start[nargs] = p.xout_len;
        // the body with its parameters replaced
        const res = p.scratch_len;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const b = body[i];
            if (b.kind == .hash and i + 1 < body.len) {
                if (p.paramIndex(&m, body[i + 1])) |k| {
                    p.stringize(p.scratch[arg_start[k]..arg_start[k + 1]], t, sink);
                    i += 1;
                    continue;
                }
            }
            if (p.paramIndex(&m, b)) |k| {
                const pasted = (i > 0 and body[i - 1].kind == .hash_hash) or (i + 1 < body.len and body[i + 1].kind == .hash_hash);
                const from = if (pasted) p.scratch[arg_start[k]..arg_start[k + 1]] else p.xout[exp_start[k]..exp_start[k + 1]];
                const first = p.scratch_len;
                for (from) |x| p.work(x);
                if (p.scratch_len > first) p.scratch[first].flags = (p.scratch[first].flags & ~lex.SPACE) | (b.flags & lex.SPACE);
                // (an empty argument next to ## leaves a placemarker: nothing)
                continue;
            }
            var c = b;
            c.pos = t.pos;
            p.work(c);
        }
        if (p.scratch_len > res) p.scratch[res].flags = (p.scratch[res].flags & ~lex.SPACE) | (t.flags & lex.SPACE);
        p.pasteAll(res);
        _ = p.push(p.scratch[res..p.scratch_len], mi);
    }

    /// `#arg`: the argument's spelling as a string token.
    fn stringize(p: *Pp, arg: []const Token, at: Token, _: Sink) void {
        var buf: [1024]u8 = undefined;
        var n: usize = 0;
        buf[0] = '"';
        n = 1;
        for (arg, 0..) |x, k| {
            const s = p.text(x);
            if (k > 0 and x.flags & lex.SPACE != 0 and n < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
            for (s) |ch| {
                if ((ch == '"' or ch == '\\') and x.kind == .string and n < buf.len) {
                    buf[n] = '\\';
                    n += 1;
                }
                if (n < buf.len) {
                    buf[n] = ch;
                    n += 1;
                }
            }
        }
        if (n < buf.len) {
            buf[n] = '"';
            n += 1;
        }
        const o = p.intern(buf[0..n]) orelse return;
        p.work(.{ .off = o, .len = @intCast(n), .kind = .string, .pos = at.pos });
    }

    /// Joins the tokens on each side of every ## in scratch[from..].
    fn pasteAll(p: *Pp, from: usize) void {
        var i = from;
        while (i < p.scratch_len) {
            if (p.scratch[i].kind != .hash_hash) {
                i += 1;
                continue;
            }
            // left: the token before (none: drop the ##)
            const has_left = i > from;
            const has_right = i + 1 < p.scratch_len;
            if (!has_left or !has_right) {
                p.remove(i, 1);
                continue;
            }
            const l = p.scratch[i - 1];
            const r = p.scratch[i + 1];
            var buf: [512]u8 = undefined;
            const ls = p.text(l);
            const rs = p.text(r);
            if (ls.len + rs.len > buf.len) return p.fail(l.line(), "pasted token too long", .{});
            @memcpy(buf[0..ls.len], ls);
            @memcpy(buf[ls.len..][0..rs.len], rs);
            const s = buf[0 .. ls.len + rs.len];
            const o = p.intern(s) orelse return;
            var one: [8]Token = undefined;
            const n = lex.lex(p.pool[o..][0..s.len], o, l.file(), l.line(), &one) orelse 0;
            var nt = l;
            if (n >= 1 and one[0].kind != .newline) {
                nt.off = one[0].off;
                nt.len = one[0].len;
                nt.kind = one[0].kind;
            }
            p.scratch[i - 1] = nt;
            p.remove(i, 2);
        }
    }

    fn remove(p: *Pp, at: usize, n: usize) void {
        std.mem.copyForwards(Token, p.scratch[at .. p.scratch_len - n], p.scratch[at + n .. p.scratch_len]);
        p.scratch_len -= n;
    }

    // ── #if ──

    fn evalIf(p: *Pp, line: []const Token) bool {
        const mark = p.scratch_len;
        defer p.scratch_len = mark;
        // `defined X` / `defined(X)` first, then everything expanded
        const pre = p.scratch_len;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const t = line[i];
            if (t.kind == .ident and eq(p.text(t), "defined")) {
                var j = i + 1;
                const paren = j < line.len and line[j].kind == .lparen;
                if (paren) j += 1;
                if (j >= line.len or line[j].kind != .ident) {
                    p.fail(t.line(), "defined needs a name", .{});
                    return false;
                }
                const v = p.find(p.text(line[j])) != null;
                if (paren) j += 1;
                const o = p.intern(if (v) "1" else "0") orelse return false;
                p.work(.{ .off = o, .len = 1, .kind = .int_lit, .pos = t.pos });
                i = j;
                continue;
            }
            p.work(t);
        }
        const pre_end = p.scratch_len;
        if (!p.push(p.scratch[pre..pre_end], NO_MACRO)) return false;
        const floor = p.nstreams - 1;
        const ex = p.xout_len;
        defer p.xout_len = ex;
        while (p.next(floor)) |t| {
            if (p.failed) return false;
            p.expandOne(t, floor, .xout);
        }
        var e = Eval{ .p = p, .t = p.xout[ex..p.xout_len] };
        const v = e.ternary();
        if (e.at != e.t.len and !p.failed) p.fail(lineOf(line), "bad #if expression", .{});
        return v != 0;
    }
};

fn lineOf(line: []const Token) u32 {
    return if (line.len > 0) line[0].line() else 0;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Eval = struct {
    p: *Pp,
    t: []const Token,
    at: usize = 0,

    fn peekK(e: *Eval) Kind {
        return if (e.at < e.t.len) e.t[e.at].kind else .eof;
    }

    fn take(e: *Eval, k: Kind) bool {
        if (e.peekK() == k) {
            e.at += 1;
            return true;
        }
        return false;
    }

    fn ternary(e: *Eval) i64 {
        const c = e.binary(0);
        if (e.take(.question)) {
            const a = e.ternary();
            _ = e.take(.colon);
            const b = e.ternary();
            return if (c != 0) a else b;
        }
        return c;
    }

    fn prec(k: Kind) u8 {
        return switch (k) {
            .or_or => 1,
            .and_and => 2,
            .pipe => 3,
            .caret => 4,
            .amp => 5,
            .eq, .ne => 6,
            .lt, .gt, .le, .ge => 7,
            .shl, .shr => 8,
            .plus, .minus => 9,
            .star, .slash, .percent => 10,
            else => 0,
        };
    }

    fn binary(e: *Eval, min: u8) i64 {
        var l = e.unary();
        while (true) {
            const k = e.peekK();
            const pr = prec(k);
            if (pr == 0 or pr <= min) break;
            e.at += 1;
            const r = e.binary(pr);
            l = switch (k) {
                .or_or => @intFromBool(l != 0 or r != 0),
                .and_and => @intFromBool(l != 0 and r != 0),
                .pipe => l | r,
                .caret => l ^ r,
                .amp => l & r,
                .eq => @intFromBool(l == r),
                .ne => @intFromBool(l != r),
                .lt => @intFromBool(l < r),
                .gt => @intFromBool(l > r),
                .le => @intFromBool(l <= r),
                .ge => @intFromBool(l >= r),
                .shl => l << @intCast(@as(u64, @bitCast(r)) & 63),
                .shr => l >> @intCast(@as(u64, @bitCast(r)) & 63),
                .plus => l +% r,
                .minus => l -% r,
                .star => l *% r,
                .slash => if (r == 0) 0 else @divTrunc(l, r),
                .percent => if (r == 0) 0 else @rem(l, r),
                else => l,
            };
        }
        return l;
    }

    fn unary(e: *Eval) i64 {
        if (e.take(.minus)) return -%e.unary();
        if (e.take(.plus)) return e.unary();
        if (e.take(.bang)) return @intFromBool(e.unary() == 0);
        if (e.take(.tilde)) return ~e.unary();
        if (e.take(.lparen)) {
            const v = e.ternary();
            _ = e.take(.rparen);
            return v;
        }
        if (e.at >= e.t.len) return 0;
        const t = e.t[e.at];
        e.at += 1;
        return switch (t.kind) {
            .int_lit => blk: {
                var u = false;
                break :blk @bitCast(lex.intValue(e.p.text(t), &u));
            },
            .float_lit => @intFromFloat(lex.floatValue(e.p.text(t))),
            .ident => if (eq(e.p.text(t), "true")) 1 else 0,
            else => 0,
        };
    }
};

// ── Tests ──

const testing = std.testing;

const TestPp = struct {
    pool: [64 * 1024]u8 = undefined,
    raw: [4096]Token = undefined,
    out: [4096]Token = undefined,
    mtoks: [4096]Token = undefined,
    scratch: [4096]Token = undefined,
    xout: [4096]Token = undefined,
    macros: [MAX_MACROS]Macro = undefined,
    logbuf: [1024]u8 = undefined,
    log: Log = undefined,
    pp: Pp = undefined,

    fn init(t: *TestPp) *Pp {
        t.log = .{ .buf = &t.logbuf };
        t.pp = .{ .pool = &t.pool, .raw = &t.raw, .out = &t.out, .mtoks = &t.mtoks, .scratch = &t.scratch, .xout = &t.xout, .macros = &t.macros, .log = &t.log };
        return &t.pp;
    }

    fn joined(t: *TestPp, buf: []u8) []const u8 {
        var n: usize = 0;
        for (t.pp.out[0..t.pp.out_len], 0..) |tok, k| {
            if (k > 0) {
                buf[n] = ' ';
                n += 1;
            }
            const s = t.pp.text(tok);
            @memcpy(buf[n..][0..s.len], s);
            n += s.len;
        }
        return buf[0..n];
    }
};

var test_pp: TestPp = undefined;

fn expectPp(src: []const u8, want: []const u8) !void {
    const p = test_pp.init();
    if (!p.run(src, "t.hlsl")) {
        std.debug.print("{s}\n", .{test_pp.log.text()});
        return error.PreprocessFailed;
    }
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(want, test_pp.joined(&buf));
}

test "macros: object, function, nested, # and ##, recursion stops" {
    try expectPp("#define A 1 + B\n#define B 2\nx = A;", "x = 1 + 2 ;");
    try expectPp("#define F(a, b) ((a) * (b))\nF(x + 1, F(y, 2))", "( ( x + 1 ) * ( ( ( y ) * ( 2 ) ) ) )");
    try expectPp("#define S(a) #a\n#define P(a, b) a##b\nS(hi there) P(tex, 2D)", "\"hi there\" tex2D");
    try expectPp("#define X X + 1\nX", "X + 1");
    try expectPp("#define LOOP [loop]\nLOOP for", "[ loop ] for");
}

test "conditionals: #if, #ifdef, #elif, #else, defined" {
    try expectPp("#define A 2\n#if A > 1 && defined(A)\nyes\n#else\nno\n#endif", "yes");
    try expectPp("#ifdef B\nb\n#elif 0\nz\n#elif 1\nc\n#else\nd\n#endif", "c");
    try expectPp("#ifndef B\n#if 0\nx\n#endif\nnb\n#endif", "nb");
    try expectPp("#ifdef ANGLE_ENABLE_LOOP_FLATTEN\n#define LOOP [loop]\n#else\n#define LOOP\n#endif\nLOOP for", "for");
}

test "defines from the call, #pragma pack_matrix, #include" {
    const p = test_pp.init();
    p.defineText("ANGLE_ENABLE_LOOP_FLATTEN", "1");
    const Inc = struct {
        fn open(_: ?*anyopaque, _: bool, name: []const u8, _: ?[]const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "a.h")) "#define FROM_A 7\n" else null;
        }
        fn close(_: ?*anyopaque, _: []const u8) void {}
    };
    p.include = .{ .open = Inc.open, .close = Inc.close };
    try testing.expect(p.run("#include \"a.h\"\n#pragma pack_matrix(row_major)\n#if ANGLE_ENABLE_LOOP_FLATTEN\nFROM_A\n#endif\n", "t.hlsl"));
    try testing.expectEqual(@as(usize, 2), p.out_len);
    try testing.expectEqual(Kind.pragma_row_major, p.out[0].kind);
    try testing.expectEqualStrings("7", p.text(p.out[1]));
}
