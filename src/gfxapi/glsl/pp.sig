//! @zpm/gfxapi glsl/pp — GLSL ES's preprocessor: comments, line
//! continuations, #version, #extension, #define (object-like and
//! function-like, `##`), #undef, #if/#ifdef/#ifndef/#elif/#else/#endif
//! (integer expressions, `defined`), #line, #error, #pragma; __LINE__,
//! __VERSION__, GL_ES and the extensions' macros. What it gives the
//! parser: the shader's tokens, macros expanded, each with its line.
//!
//! Directives are handled line by line as they come; the lines between
//! two of them are expanded together (a macro's arguments may span
//! lines). Expansion runs over a stack of token streams, not recursion: a
//! macro is off while its own stream is read, so a macro naming itself
//! stops there.
//!
//! Allocation-free: tokens, macros and text live in the caller's Scratch.

const std = @import("std");
const lex = @import("lex.sig");
const Token = lex.Token;
const Kind = lex.Kind;

/// The compile's messages (Mesa's form: `0:LINE: error: ...`).
pub const Log = struct {
    buf: []u8,
    len: usize = 0,
    errors: u32 = 0,

    pub fn err(l: *Log, line: u32, comptime fmt: []const u8, args: anytype) void {
        l.errors += 1;
        l.put(line, "error", fmt, args);
    }

    pub fn warn(l: *Log, line: u32, comptime fmt: []const u8, args: anytype) void {
        l.put(line, "warning", fmt, args);
    }

    fn put(l: *Log, line: u32, what: []const u8, comptime fmt: []const u8, args: anytype) void {
        // (a full log keeps its first messages)
        const room = l.buf[l.len..];
        const head = std.fmt.bufPrint(room, "0:{d}: {s}: ", .{ line, what }) catch return;
        const body = std.fmt.bufPrint(room[head.len..], fmt ++ "\n", args) catch return;
        l.len += head.len + body.len;
    }

    pub fn text(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }
};

pub const MAX_MACROS = 1024;
pub const MAX_MACRO_TOKENS = 32768;
pub const MAX_PARAM_NAMES = 4096;
const MAX_STREAMS = 64;
const MAX_IF = 64;
const MAX_ARGS = 32;
const TEXT_BYTES = 64 * 1024;

const Macro = struct {
    name: []const u8,
    func: bool = false,
    /// parameter names: pnames[params .. params + nparams]
    params: u32 = 0,
    nparams: u8 = 0,
    /// replacement: mtoks[body .. body + len]
    body: u32 = 0,
    len: u32 = 0,
    /// a predefined one (#undef and #define of it are errors)
    builtin: bool = false,
};

const Stream = struct { toks: []const Token, at: usize = 0, macro: ?u16 = null };

pub const Extensions = struct {
    egl_image_external: bool = false,
    derivatives: bool = false,
    texture_lod: bool = false,
};

pub const Pp = struct {
    log: *Log,
    /// the tokens out
    out: []Token,
    n: usize = 0,
    /// working tokens (a line run, substitutions), used stack-wise
    work: []Token,
    wn: usize = 0,
    version: u32 = 100,
    es: bool = true,
    fragment: bool = false,
    ext: Extensions = .{},
    macros: [MAX_MACROS]Macro = undefined,
    nmacros: usize = 0,
    mtoks: [MAX_MACRO_TOKENS]Token = undefined,
    nmtoks: usize = 0,
    pnames: [MAX_PARAM_NAMES][]const u8 = undefined,
    npnames: usize = 0,
    streams: [MAX_STREAMS]Stream = undefined,
    nstreams: usize = 0,
    text: [TEXT_BYTES]u8 = undefined,
    ntext: usize = 0,
    line: u32 = 1,
    overflow: bool = false,

    // ── Output and storage ─────────────────────────────────────────────────

    fn emit(p: *Pp, t: Token) void {
        if (p.n == p.out.len) {
            if (!p.overflow) p.log.err(t.line, "shader too long ({d} tokens at most)", .{p.out.len});
            p.overflow = true;
            return;
        }
        p.out[p.n] = t;
        p.n += 1;
    }

    fn work1(p: *Pp, t: Token) bool {
        if (p.wn == p.work.len) {
            if (!p.overflow) p.log.err(t.line, "shader too long (macros expand to more than {d} tokens)", .{p.work.len});
            p.overflow = true;
            return false;
        }
        p.work[p.wn] = t;
        p.wn += 1;
        return true;
    }

    /// Text the preprocessor makes (a pasted token, __LINE__'s number).
    fn keepText(p: *Pp, s: []const u8) ?[]const u8 {
        if (p.ntext + s.len > p.text.len) return null;
        @memcpy(p.text[p.ntext..][0..s.len], s);
        defer p.ntext += s.len;
        return p.text[p.ntext..][0..s.len];
    }

    fn find(p: *Pp, name: []const u8) ?u16 {
        var i = p.nmacros;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.macros[i].name, name)) return @intCast(i);
        }
        return null;
    }

    /// A predefined object-like macro of one token.
    fn predefine(p: *Pp, name: []const u8, value: []const u8, kind: Kind) void {
        p.mtoks[p.nmtoks] = .{ .kind = kind, .line = 0, .text = value };
        p.macros[p.nmacros] = .{ .name = name, .body = @intCast(p.nmtoks), .len = 1, .builtin = true };
        p.nmtoks += 1;
        p.nmacros += 1;
    }

    // ── The source, line by line ───────────────────────────────────────────

    /// Preprocesses `src` (`clean`: scratch as long as it); the tokens are
    /// out[0..n] after, the last an eof.
    pub fn run(p: *Pp, src: []const u8, clean: []u8) void {
        const text = stripComments(p, src, clean);
        p.predefine("GL_ES", "1", .int_lit);
        p.predefine("__FILE__", "0", .int_lit);
        p.predefine("__LINE__", "0", .int_lit);
        p.predefine("GL_OES_EGL_image_external", "1", .int_lit);
        p.predefine("GL_OES_EGL_image_external_essl3", "1", .int_lit);
        p.predefine("GL_OES_standard_derivatives", "1", .int_lit);
        p.predefine("GL_EXT_shader_texture_lod", "1", .int_lit);
        if (p.fragment) p.predefine("GL_FRAGMENT_PRECISION_HIGH", "1", .int_lit);
        const version_at = p.nmacros;
        p.predefine("__VERSION__", "100", .int_lit);
        var conds: [MAX_IF]Cond = undefined;
        var nconds: usize = 0;
        var seen_code = false;
        var it = std.mem.splitScalar(u8, text, '\n');
        p.line = 1;
        while (it.next()) |raw| : (p.line += 1) {
            // (joined continuation lines were blanked: their line count stays)
            const line = raw;
            const active = nconds == 0 or conds[nconds - 1].active;
            const trimmed = std.mem.trimStart(u8, line, " \t\r\x0b\x0c");
            if (trimmed.len > 0 and trimmed[0] == '#') {
                p.flush();
                var l = lex.Lexer{ .src = trimmed[1..], .line = p.line };
                var dt: [256]Token = undefined;
                var nd: usize = 0;
                while (nd < dt.len) {
                    const t = l.next();
                    if (t.kind == .eof) break;
                    dt[nd] = t;
                    nd += 1;
                }
                const d = dt[0..nd];
                if (d.len == 0) continue;
                const name = d[0].text;
                // conditionals first: they count even where code is skipped
                if (std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "ifdef") or std.mem.eql(u8, name, "ifndef")) {
                    if (nconds == MAX_IF) {
                        p.log.err(p.line, "#if nested too deep", .{});
                        continue;
                    }
                    var v = false;
                    if (active) {
                        if (name.len == 2) {
                            v = p.evalIf(d[1..]) != 0;
                        } else {
                            if (d.len < 2 or d[1].kind != .ident) p.log.err(p.line, "#{s} needs a macro name", .{name}) else v = (p.find(d[1].text) != null) == (name.len == 5);
                        }
                    }
                    conds[nconds] = .{ .parent = active, .active = active and v, .taken = v };
                    nconds += 1;
                    continue;
                }
                if (std.mem.eql(u8, name, "elif") or std.mem.eql(u8, name, "else") or std.mem.eql(u8, name, "endif")) {
                    if (nconds == 0) {
                        p.log.err(p.line, "#{s} without #if", .{name});
                        continue;
                    }
                    const c = &conds[nconds - 1];
                    if (name[1] == 'n') {
                        nconds -= 1;
                    } else if (c.seen_else) {
                        p.log.err(p.line, "#{s} after #else", .{name});
                    } else if (name[1] == 'l' and name[2] == 's') {
                        c.seen_else = true;
                        c.active = c.parent and !c.taken;
                        c.taken = true;
                    } else {
                        const v = c.parent and !c.taken and p.evalIf(d[1..]) != 0;
                        c.active = v;
                        c.taken = c.taken or v;
                    }
                    continue;
                }
                if (!active) continue;
                if (std.mem.eql(u8, name, "version")) {
                    if (seen_code) p.log.err(p.line, "#version must come first", .{});
                    if (d.len < 2 or d[1].kind != .int_lit) {
                        p.log.err(p.line, "#version needs a number", .{});
                        continue;
                    }
                    p.version = lex.intValue(d[1].text) orelse 0;
                    const es = d.len >= 3 and std.mem.eql(u8, d[2].text, "es");
                    if (p.version == 300 and !es) p.log.err(p.line, "#version 300 needs `es`", .{});
                    if (p.version != 100 and p.version != 300) p.log.err(p.line, "GLSL ES {d} is not supported (100 and 300 es are)", .{p.version});
                    p.mtoks[p.macros[version_at].body].text = if (p.version == 300) "300" else "100";
                    seen_code = true;
                    continue;
                }
                seen_code = true;
                if (std.mem.eql(u8, name, "define")) {
                    p.define(d[1..]);
                } else if (std.mem.eql(u8, name, "undef")) {
                    if (d.len < 2 or d[1].kind != .ident) {
                        p.log.err(p.line, "#undef needs a macro name", .{});
                    } else if (p.find(d[1].text)) |m| {
                        if (p.macros[m].builtin) p.log.err(p.line, "cannot #undef {s}", .{d[1].text}) else p.macros[m].name = "";
                    }
                } else if (std.mem.eql(u8, name, "extension")) {
                    p.extension(d[1..]);
                } else if (std.mem.eql(u8, name, "error")) {
                    const after = @intFromPtr(d[0].text.ptr) + d[0].text.len - @intFromPtr(trimmed.ptr);
                    p.log.err(p.line, "#error {s}", .{std.mem.trim(u8, trimmed[after..], " \t\r")});
                } else if (std.mem.eql(u8, name, "line")) {
                    if (d.len >= 2 and d[1].kind == .int_lit) {
                        if (lex.intValue(d[1].text)) |v| p.line = v -% 1;
                    } else p.log.err(p.line, "#line needs a number", .{});
                } else if (!std.mem.eql(u8, name, "pragma")) {
                    p.log.err(p.line, "unknown directive #{s}", .{name});
                }
                continue;
            }
            if (!active) continue;
            // a line of code: its tokens wait for the run's expansion
            var l = lex.Lexer{ .src = line, .line = p.line };
            while (true) {
                const t = l.next();
                if (t.kind == .eof) break;
                seen_code = true;
                if (!p.work1(t)) break;
            }
        }
        if (nconds != 0) p.log.err(p.line, "#if without #endif", .{});
        p.flush();
        p.emit(.{ .kind = .eof, .line = p.line });
    }

    // ── #define, #extension ────────────────────────────────────────────────

    fn define(p: *Pp, d: []const Token) void {
        if (d.len == 0 or d[0].kind != .ident) return p.log.err(p.line, "#define needs a macro name", .{});
        const name = d[0].text;
        if (std.mem.startsWith(u8, name, "GL_")) return p.log.err(p.line, "macro names beginning GL_ are reserved: {s}", .{name});
        if (std.mem.indexOf(u8, name, "__") != null) p.log.warn(p.line, "macro names with __ are reserved: {s}", .{name});
        if (p.find(name)) |m| {
            if (p.macros[m].builtin) return p.log.err(p.line, "cannot redefine {s}", .{name});
        }
        if (p.nmacros == MAX_MACROS) return p.log.err(p.line, "too many macros", .{});
        var m = Macro{ .name = name };
        var at: usize = 1;
        // function-like: `(` right after the name (no space)
        if (d.len > 1 and d[1].kind == .lparen and d[1].text.ptr == name.ptr + name.len) {
            m.func = true;
            m.params = @intCast(p.npnames);
            at = 2;
            while (at < d.len and d[at].kind != .rparen) : (at += 1) {
                if (d[at].kind == .comma) continue;
                if (d[at].kind != .ident or p.npnames == MAX_PARAM_NAMES or m.nparams == MAX_ARGS) return p.log.err(p.line, "bad parameters of macro {s}", .{name});
                p.pnames[p.npnames] = d[at].text;
                p.npnames += 1;
                m.nparams += 1;
            }
            if (at == d.len) return p.log.err(p.line, "macro {s}: unclosed parameters", .{name});
            at += 1;
        }
        const body = d[at..];
        if (p.nmtoks + body.len > MAX_MACRO_TOKENS) return p.log.err(p.line, "macros too long", .{});
        m.body = @intCast(p.nmtoks);
        m.len = @intCast(body.len);
        @memcpy(p.mtoks[p.nmtoks..][0..body.len], body);
        p.nmtoks += body.len;
        p.macros[p.nmacros] = m;
        p.nmacros += 1;
    }

    fn extension(p: *Pp, d: []const Token) void {
        if (d.len < 3 or d[0].kind != .ident or d[1].kind != .colon or d[2].kind != .ident) return p.log.err(p.line, "#extension name : behavior", .{});
        const name = d[0].text;
        const behavior = d[2].text;
        const on = !std.mem.eql(u8, behavior, "disable");
        if (std.mem.eql(u8, name, "all")) {
            if (std.mem.eql(u8, behavior, "require") or std.mem.eql(u8, behavior, "enable")) p.log.err(p.line, "#extension all : {s}", .{behavior});
            return;
        }
        if (std.mem.eql(u8, name, "GL_OES_EGL_image_external") or std.mem.eql(u8, name, "GL_OES_EGL_image_external_essl3")) {
            p.ext.egl_image_external = on;
        } else if (std.mem.eql(u8, name, "GL_OES_standard_derivatives")) {
            p.ext.derivatives = on;
        } else if (std.mem.eql(u8, name, "GL_EXT_shader_texture_lod")) {
            p.ext.texture_lod = on;
        } else if (std.mem.eql(u8, behavior, "require")) {
            p.log.err(p.line, "extension {s} is not supported", .{name});
        } else p.log.warn(p.line, "extension {s} is not supported", .{name});
    }

    // ── Expansion ──────────────────────────────────────────────────────────

    fn isActive(p: *const Pp, m: u16) bool {
        for (p.streams[0..p.nstreams]) |s| {
            if (s.macro == m) return true;
        }
        return false;
    }

    fn push(p: *Pp, toks: []const Token, m: ?u16) bool {
        if (p.nstreams == MAX_STREAMS) {
            p.log.err(p.line, "macros nested too deep", .{});
            return false;
        }
        p.streams[p.nstreams] = .{ .toks = toks, .macro = m };
        p.nstreams += 1;
        return true;
    }

    /// The next token of the streams above `floor` (exhausted ones go).
    fn nextTok(p: *Pp, floor: usize) ?Token {
        while (p.nstreams > floor) {
            const s = &p.streams[p.nstreams - 1];
            if (s.at < s.toks.len) {
                s.at += 1;
                return s.toks[s.at - 1];
            }
            p.nstreams -= 1;
        }
        return null;
    }

    /// The next token's kind, without taking it.
    fn peekKind(p: *Pp, floor: usize) ?Kind {
        while (p.nstreams > floor) {
            const s = &p.streams[p.nstreams - 1];
            if (s.at < s.toks.len) return s.toks[s.at].kind;
            p.nstreams -= 1;
        }
        return null;
    }

    /// The pending run's tokens (work[0..wn]) expanded into out.
    fn flush(p: *Pp) void {
        if (p.wn == 0) return;
        const n = p.wn;
        p.expand(p.work[0..n], null);
        p.wn = 0;
    }

    /// Tokens out of an expansion that are not the shader's (an #if's).
    const Local = struct { toks: []Token, n: usize = 0 };

    /// `src` expanded, into out (or `local`).
    fn expand(p: *Pp, src: []const Token, local: ?*Local) void {
        const base = p.nstreams;
        if (!p.push(src, null)) return;
        while (p.nstreams > base) {
            const t = p.nextTok(base) orelse break;
            if (t.kind == .ident) {
                if (p.find(t.text)) |m| {
                    if (!p.isActive(m) and p.macros[m].name.len > 0) {
                        if (p.invoke(m, t, base)) continue;
                    }
                }
            }
            if (local) |l| {
                if (l.n == l.toks.len) break;
                l.toks[l.n] = t;
                l.n += 1;
            } else p.emit(t);
        }
        p.nstreams = base;
    }

    /// Macro m at token t: its replacement pushed (true), or not an
    /// invocation (false: t stays itself).
    fn invoke(p: *Pp, m: u16, t: Token, base: usize) bool {
        const mac = p.macros[m];
        if (std.mem.eql(u8, mac.name, "__LINE__")) {
            var buf: [12]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{t.line}) catch "0";
            const text = p.keepText(s) orelse "0";
            const at = p.wn;
            if (!p.work1(.{ .kind = .int_lit, .line = t.line, .text = text })) return true;
            return p.push(p.work[at .. at + 1], null);
        }
        if (!mac.func) {
            // (the replacement's tokens take the use's line)
            const at = p.wn;
            for (p.mtoks[mac.body..][0..mac.len]) |b| {
                var c = b;
                c.line = t.line;
                if (!p.work1(c)) return true;
            }
            return p.push(p.work[at..p.wn], m);
        }
        // function-like: `(` must follow, else it is a plain name
        if (p.peekKind(base) != .lparen) return false;
        _ = p.nextTok(base);
        // the arguments, raw, onto the work area
        var arg_at: [MAX_ARGS + 1]usize = undefined;
        var nargs: usize = 0;
        arg_at[0] = p.wn;
        var depth: u32 = 0;
        while (true) {
            const a = p.nextTok(base) orelse {
                p.log.err(t.line, "macro {s}: unclosed arguments", .{mac.name});
                return true;
            };
            if (a.kind == .lparen) depth += 1;
            if (a.kind == .rparen) {
                if (depth == 0) break;
                depth -= 1;
            }
            if (a.kind == .comma and depth == 0) {
                nargs += 1;
                if (nargs > MAX_ARGS) {
                    p.log.err(t.line, "macro {s}: too many arguments", .{mac.name});
                    return true;
                }
                arg_at[nargs] = p.wn;
                continue;
            }
            if (!p.work1(a)) return true;
        }
        // (`f()` with no parameters: no arguments; else one more than commas)
        if (!(mac.nparams == 0 and nargs == 0 and p.wn == arg_at[0])) nargs += 1;
        arg_at[nargs] = p.wn;
        if (nargs != mac.nparams) {
            p.log.err(t.line, "macro {s} takes {d} arguments, not {d}", .{ mac.name, mac.nparams, nargs });
            return true;
        }
        // the replacement: parameters replaced by their arguments, `##` pasted
        const at = p.wn;
        const body = p.mtoks[mac.body..][0..mac.len];
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const b = body[i];
            if (b.kind == .hash_hash) {
                // (the token before and the next pasted into one)
                if (p.wn == at or i + 1 == body.len) continue;
                i += 1;
                const nxt = body[i];
                const right: []const Token = if (param(p, mac, nxt)) |pi| p.work[arg_at[pi]..arg_at[pi + 1]] else (&[_]Token{nxt})[0..];
                if (right.len == 0) continue;
                const left = p.work[p.wn - 1];
                var paste: [256]u8 = undefined;
                if (left.text.len + right[0].text.len > paste.len) continue;
                @memcpy(paste[0..left.text.len], left.text);
                @memcpy(paste[left.text.len..][0..right[0].text.len], right[0].text);
                const s = p.keepText(paste[0 .. left.text.len + right[0].text.len]) orelse continue;
                var l = lex.Lexer{ .src = s, .line = t.line };
                p.work[p.wn - 1] = l.next();
                for (right[1..]) |r| {
                    if (!p.work1(r)) return true;
                }
                continue;
            }
            if (param(p, mac, b)) |pi| {
                for (arg_at[pi]..arg_at[pi + 1]) |j| {
                    if (!p.work1(p.work[j])) return true;
                }
                continue;
            }
            var c = b;
            c.line = t.line;
            if (!p.work1(c)) return true;
        }
        return p.push(p.work[at..p.wn], m);
    }

    fn param(p: *const Pp, mac: Macro, t: Token) ?usize {
        if (t.kind != .ident) return null;
        for (p.pnames[mac.params..][0..mac.nparams], 0..) |n, i| {
            if (std.mem.eql(u8, n, t.text)) return i;
        }
        return null;
    }

    // ── #if's expressions ──────────────────────────────────────────────────

    /// An #if's value: `defined` first, then macros expanded, then integer
    /// arithmetic (a name left over is 0).
    fn evalIf(p: *Pp, d: []const Token) i64 {
        const mark = p.wn;
        defer p.wn = mark;
        // `defined X` and `defined ( X )` to 1 or 0
        var i: usize = 0;
        const raw_at = p.wn;
        while (i < d.len) : (i += 1) {
            if (d[i].kind == .ident and std.mem.eql(u8, d[i].text, "defined")) {
                var j = i + 1;
                const paren = j < d.len and d[j].kind == .lparen;
                if (paren) j += 1;
                if (j >= d.len or d[j].kind != .ident) {
                    p.log.err(p.line, "`defined` needs a macro name", .{});
                    return 0;
                }
                const yes = p.find(d[j].text) != null and p.macros[p.find(d[j].text).?].name.len > 0;
                if (paren) {
                    j += 1;
                    if (j >= d.len or d[j].kind != .rparen) {
                        p.log.err(p.line, "`defined(` needs `)`", .{});
                        return 0;
                    }
                }
                if (!p.work1(.{ .kind = .int_lit, .line = p.line, .text = if (yes) "1" else "0" })) return 0;
                i = j;
                continue;
            }
            if (!p.work1(d[i])) return 0;
        }
        const raw_end = p.wn;
        var toks: [512]Token = undefined;
        var local = Local{ .toks = &toks };
        p.expand(p.work[raw_at..raw_end], &local);
        var e = Eval{ .p = p, .t = toks[0..local.n] };
        const v = e.expr(0);
        if (e.at < e.t.len) p.log.err(p.line, "bad #if expression", .{});
        return v;
    }
};

const Cond = struct { parent: bool, active: bool, taken: bool, seen_else: bool = false };

const Eval = struct {
    p: *Pp,
    t: []const Token,
    at: usize = 0,

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

    fn expr(e: *Eval, min: u8) i64 {
        var l = e.unary();
        while (e.at < e.t.len) {
            const k = e.t[e.at].kind;
            const pr = prec(k);
            if (pr == 0 or pr <= min) break;
            e.at += 1;
            const r = e.expr(pr);
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
                .shl => l << @intCast(std.math.clamp(r, 0, 63)),
                .shr => l >> @intCast(std.math.clamp(r, 0, 63)),
                .plus => l +% r,
                .minus => l -% r,
                .star => l *% r,
                .slash, .percent => blk: {
                    if (r == 0) {
                        e.p.log.err(e.p.line, "division by zero in #if", .{});
                        break :blk 0;
                    }
                    break :blk if (k == .slash) @divTrunc(l, r) else @rem(l, r);
                },
                else => l,
            };
        }
        return l;
    }

    fn unary(e: *Eval) i64 {
        if (e.at >= e.t.len) {
            e.p.log.err(e.p.line, "#if expression ends early", .{});
            return 0;
        }
        const t = e.t[e.at];
        e.at += 1;
        switch (t.kind) {
            .plus => return e.unary(),
            .minus => return -%e.unary(),
            .bang => return @intFromBool(e.unary() == 0),
            .tilde => return ~e.unary(),
            .lparen => {
                const v = e.expr(0);
                if (e.at < e.t.len and e.t[e.at].kind == .rparen) e.at += 1 else e.p.log.err(e.p.line, "`(` without `)` in #if", .{});
                return v;
            },
            .int_lit, .uint_lit => return lex.intValue(t.text) orelse 0,
            .ident => return 0,
            else => {
                e.p.log.err(e.p.line, "bad token `{s}` in #if", .{t.text});
                return 0;
            },
        }
    }
};

/// The source with comments blanked (newlines kept) and continuation
/// lines joined (each `\` + newline moved to the line's end, so line
/// numbers stay), into `clean`.
fn stripComments(p: *Pp, src: []const u8, clean: []u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    var pending_newlines: usize = 0;
    var line: u32 = 1;
    while (i < src.len and o < clean.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len and (src[i + 1] == '\n' or (src[i + 1] == '\r' and i + 2 < src.len and src[i + 2] == '\n'))) {
            i += if (src[i + 1] == '\r') 3 else 2;
            pending_newlines += 1;
            line += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            clean[o] = ' ';
            o += 1;
            while (i < src.len and !(src[i] == '*' and i + 1 < src.len and src[i + 1] == '/')) : (i += 1) {
                if (src[i] == '\n') {
                    line += 1;
                    if (o < clean.len) {
                        clean[o] = '\n';
                        o += 1;
                    }
                }
            }
            if (i >= src.len) p.log.err(line, "unclosed comment", .{});
            i += 2;
            continue;
        }
        if (c == '\n') {
            line += 1;
            if (o < clean.len) {
                clean[o] = '\n';
                o += 1;
            }
            while (pending_newlines > 0 and o < clean.len) : (pending_newlines -= 1) {
                clean[o] = '\n';
                o += 1;
            }
            i += 1;
            continue;
        }
        clean[o] = c;
        o += 1;
        i += 1;
    }
    return clean[0..o];
}

// ── Tests ──────────────────────────────────────────────────────────────────

var t_out: [512]Token = undefined;
var t_work: [512]Token = undefined;
var t_clean: [4096]u8 = undefined;
var t_logbuf: [2048]u8 = undefined;
var t_pp: Pp = undefined;
var t_log: Log = undefined;

fn testRun(src: []const u8) *Pp {
    t_log = .{ .buf = &t_logbuf };
    t_pp = .{ .log = &t_log, .out = &t_out, .work = &t_work };
    t_pp.run(src, &t_clean);
    return &t_pp;
}

fn joined(p: *const Pp, buf: []u8) []const u8 {
    var n: usize = 0;
    for (p.out[0 .. p.n - 1]) |t| {
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n..][0..t.text.len], t.text);
        n += t.text.len;
    }
    return buf[0..n];
}

test "pp: macros, conditionals, comments, lines" {
    const src =
        \\#version 300 es
        \\// a comment
        \\#define N 4
        \\#define SQ(x) ((x) * (x))
        \\#define CAT(a, b) a ## b
        \\#define FLAT flat
        \\/* a block
        \\   comment */ #define LATER 1
        \\#if defined(N) && N > 3 && !defined(NOPE)
        \\FLAT out int v[N]; float y = SQ(N + 1);
        \\#elif 1
        \\wrong
        \\#else
        \\wrong
        \\#endif
        \\#ifdef NOPE
        \\wrong
        \\#endif
        \\int CAT(my, Var) = __LINE__ + __VERSION__;
        \\float z = SQ(
        \\  2.0);
    ;
    const p = testRun(src);
    try std.testing.expectEqual(@as(u32, 0), t_log.errors);
    try std.testing.expectEqual(@as(u32, 300), p.version);
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("flat out int v [ 4 ] ; float y = ( ( 4 + 1 ) * ( 4 + 1 ) ) ; int myVar = 19 + 300 ; float z = ( ( 2.0 ) * ( 2.0 ) ) ;", joined(p, &buf));
    // (the line numbers are the source's)
    try std.testing.expectEqual(@as(u32, 10), p.out[0].line);
    for (p.out[0..p.n]) |t| {
        if (std.mem.eql(u8, t.text, "myVar")) try std.testing.expectEqual(@as(u32, 19), t.line);
        if (std.mem.eql(u8, t.text, "2.0")) try std.testing.expectEqual(@as(u32, 21), t.line);
    }
}

test "pp: what it refuses" {
    _ = testRun("#version 310 es\n#if\n#endif\n#extension GL_FOO : require\n#define GL_X 1\n#error stop\n#if 1\n");
    const log = t_log.text();
    try std.testing.expect(std.mem.indexOf(u8, log, "GLSL ES 310 is not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "extension GL_FOO is not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "GL_ are reserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "0:6: error: #error stop") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "#if without #endif") != null);
    // a macro naming itself stops there
    const p = testRun("#define x x + 1\nx\n");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x + 1", joined(p, &buf));
}
