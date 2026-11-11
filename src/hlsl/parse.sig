//! @zpm/hlsl parse — HLSL (Shader Model 4 and 5) into the Ast: global
//! variables with their storage classes, semantics, registers and pack
//! offsets; structs, typedefs, cbuffers and tbuffers; functions (with
//! overloads, in/out/inout and default parameters, attributes); statements
//! with flow attributes; C's expressions with HLSL's constructors, casts,
//! swizzles, methods and initializer lists. Names are resolved as they are
//! read; array sizes are evaluated as they are read.

const std = @import("std");
const lex = @import("lex.sig");
const ast = @import("ast.sig");
const pp = @import("pp.sig");
const Token = lex.Token;
const Kind = lex.Kind;
const Ast = ast.Ast;
const NONE = ast.NONE;

const MAX_SCOPE = 16384;

pub const Parser = struct {
    a: *Ast,
    t: []const Token,
    pool: []const u8,
    log: *pp.Log,
    at: usize = 0,
    /// the visible symbols (newest last) and where each scope starts
    scope: [MAX_SCOPE]u32 = undefined,
    nscope: usize = 0,
    marks: [256]usize = undefined,
    nmarks: usize = 0,
    /// #pragma pack_matrix: the default packing of matrices
    default_pack: ast.Pack = .default,
    failed: bool = false,
    /// the function being parsed (for its parameters' assignment flags)
    in_function: bool = false,

    // ── tokens ──

    fn peek(p: *const Parser) Kind {
        return p.t[p.at].kind;
    }

    fn peekAt(p: *const Parser, k: usize) Kind {
        const i = @min(p.at + k, p.t.len - 1);
        return p.t[i].kind;
    }

    fn tok(p: *const Parser) Token {
        return p.t[p.at];
    }

    fn text(p: *const Parser, t: Token) []const u8 {
        return p.pool[t.off..][0..t.len];
    }

    fn cur(p: *const Parser) []const u8 {
        return p.text(p.t[p.at]);
    }

    fn curIs(p: *const Parser, s: []const u8) bool {
        return p.peek() == .ident and std.mem.eql(u8, p.cur(), s);
    }

    fn advance(p: *Parser) Token {
        const t = p.t[p.at];
        if (t.kind != .eof) p.at += 1;
        return t;
    }

    fn accept(p: *Parser, k: Kind) bool {
        if (p.peek() == k) {
            p.at += 1;
            return true;
        }
        return false;
    }

    fn acceptWord(p: *Parser, s: []const u8) bool {
        if (p.curIs(s)) {
            p.at += 1;
            return true;
        }
        return false;
    }

    fn line(p: *const Parser) u32 {
        return p.t[p.at].line();
    }

    pub fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) void {
        if (!p.failed) p.log.err(p.line(), fmt, args);
        p.failed = true;
        // (stop: every later read sees the end)
        p.at = p.t.len - 1;
    }

    fn expect(p: *Parser, k: Kind) bool {
        if (p.accept(k)) return true;
        p.fail("syntax error: '{s}' expected, found '{s}'", .{ lex.spelling(k), if (p.peek() == .eof) "end of file" else p.cur() });
        return false;
    }

    fn expectIdent(p: *Parser) ?Token {
        if (p.peek() != .ident) {
            p.fail("syntax error: a name expected, found '{s}'", .{p.cur()});
            return null;
        }
        return p.advance();
    }

    // ── scopes ──

    fn pushScope(p: *Parser) void {
        if (p.nmarks < p.marks.len) {
            p.marks[p.nmarks] = p.nscope;
            p.nmarks += 1;
        }
    }

    fn popScope(p: *Parser) void {
        if (p.nmarks > 0) {
            p.nmarks -= 1;
            p.nscope = p.marks[p.nmarks];
        }
    }

    fn declare(p: *Parser, s: u32) void {
        if (p.nscope >= MAX_SCOPE) return p.fail("too many names", .{});
        p.scope[p.nscope] = s;
        p.nscope += 1;
    }

    fn lookup(p: *const Parser, name: []const u8) ?u32 {
        var i = p.nscope;
        while (i > 0) {
            i -= 1;
            const s = p.scope[i];
            if (std.mem.eql(u8, p.a.symName(s), name)) return s;
        }
        return null;
    }

    fn newSym(p: *Parser, s: ast.Sym) u32 {
        if (p.a.nsyms >= ast.MAX_SYMS) {
            p.fail("too many symbols", .{});
            return 0;
        }
        const i = p.a.nsyms;
        p.a.syms[i] = s;
        p.a.nsyms += 1;
        return i;
    }

    fn newNode(p: *Parser, kind: ast.NodeKind) u32 {
        return p.a.node(kind, @intCast(p.at)) orelse {
            p.fail("shader too large", .{});
            return 0;
        };
    }

    fn addGlobal(p: *Parser, s: u32) void {
        if (p.a.nglobals < ast.MAX_SYMS) {
            p.a.globals[p.a.nglobals] = s;
            p.a.nglobals += 1;
        }
    }

    // ── the file ──

    pub fn parse(p: *Parser) bool {
        while (p.peek() != .eof and !p.failed) p.topLevel();
        return !p.failed;
    }

    fn topLevel(p: *Parser) void {
        switch (p.peek()) {
            .semicolon => {
                _ = p.advance();
                return;
            },
            .pragma_row_major => {
                _ = p.advance();
                p.default_pack = .row;
                return;
            },
            .pragma_column_major => {
                _ = p.advance();
                p.default_pack = .column;
                return;
            },
            else => {},
        }
        if (p.curIs("cbuffer") or p.curIs("tbuffer")) return p.cbuffer();
        if (p.curIs("typedef")) return p.typedef();
        if (p.curIs("technique") or p.curIs("technique10") or p.curIs("technique11")) return p.skipBlock();
        // function attributes
        var max_vertex: u32 = 0;
        while (p.peek() == .lbracket) {
            _ = p.advance();
            const name = p.expectIdent() orelse return;
            var first: i64 = 0;
            if (p.accept(.lparen)) {
                var k: usize = 0;
                while (p.peek() != .rparen and p.peek() != .eof) : (k += 1) {
                    const e = p.assignment();
                    if (k == 0) first = p.constInt(e) orelse 0;
                    if (!p.accept(.comma)) break;
                }
                if (!p.expect(.rparen)) return;
            }
            if (!p.expect(.rbracket)) return;
            if (std.mem.eql(u8, p.text(name), "maxvertexcount")) max_vertex = @intCast(@max(first, 0));
        }
        var flags: u32 = 0;
        const ty = p.typeSpec(&flags, true) orelse return;
        if (p.accept(.semicolon)) return; // (a struct declared alone)
        const name = p.expectIdent() orelse return;
        if (p.peek() == .lparen) return p.function(ty, flags, name, max_vertex);
        p.globalVars(ty, flags, name);
    }

    fn skipBlock(p: *Parser) void {
        while (p.peek() != .lbrace and p.peek() != .eof) _ = p.advance();
        var depth: u32 = 0;
        while (p.peek() != .eof) {
            const k = p.advance().kind;
            if (k == .lbrace) depth += 1;
            if (k == .rbrace) {
                depth -= 1;
                if (depth == 0) break;
            }
        }
    }

    fn typedef(p: *Parser) void {
        _ = p.advance();
        var flags: u32 = 0;
        const base = p.typeSpec(&flags, true) orelse return;
        while (true) {
            const name = p.expectIdent() orelse return;
            const ty = p.arrayDims(base) orelse return;
            const s = p.newSym(.{ .kind = .typename, .name_off = name.off, .name_len = name.len, .ty = ty, .line = name.line() });
            p.declare(s);
            if (!p.accept(.comma)) break;
        }
        _ = p.expect(.semicolon);
    }

    fn cbuffer(p: *Parser) void {
        const kw = p.advance();
        const tb = std.mem.eql(u8, p.text(kw), "tbuffer");
        const name = p.expectIdent() orelse return;
        const cb = p.newSym(.{ .kind = .cbuffer, .name_off = name.off, .name_len = name.len, .flags = if (tb) ast.F_TBUFFER else 0, .line = name.line() });
        var dummy_sem: [2]u32 = undefined;
        _ = p.postfixDecl(cb, &dummy_sem);
        if (!p.expect(.lbrace)) return;
        p.a.syms[cb].cbuf = p.a.nsyms;
        p.addGlobal(cb);
        while (p.peek() != .rbrace and p.peek() != .eof and !p.failed) {
            if (p.accept(.semicolon)) continue;
            var flags: u32 = 0;
            const ty = p.typeSpec(&flags, true) orelse return;
            if (p.accept(.semicolon)) continue;
            while (true) {
                const vn = p.expectIdent() orelse return;
                const vty = p.arrayDims(ty) orelse return;
                const s = p.newSym(.{ .kind = .variable, .storage = .cbuffer_member, .name_off = vn.off, .name_len = vn.len, .ty = p.packTy(vty, flags), .flags = flags, .cbuf = cb, .line = vn.line() });
                var sem: [2]u32 = undefined;
                if (!p.postfixDecl(s, &sem)) return;
                if (p.accept(.assign)) _ = p.initializer();
                p.declare(s);
                p.a.syms[cb].nparams += 1;
                if (!p.accept(.comma)) break;
            }
            if (!p.expect(.semicolon)) return;
        }
        _ = p.expect(.rbrace);
        _ = p.accept(.semicolon);
    }

    /// A matrix type with its packing: the declaration's modifier, else
    /// the pragma's, else the default (the compile flags decide).
    fn packTy(p: *Parser, ty: u32, flags: u32) u32 {
        const pk: ast.Pack = if (flags & ast.F_ROW_MAJOR != 0) .row else if (flags & ast.F_COL_MAJOR != 0) .column else p.default_pack;
        if (pk == .default) return ty;
        return p.withPackIfDefault(ty, pk);
    }

    fn withPackIfDefault(p: *Parser, ty: u32, pk: ast.Pack) u32 {
        const t = p.a.types[ty];
        return switch (t.class) {
            .matrix => if (t.pack == .default) p.a.matrix(t.base, t.rows, t.cols, pk) else ty,
            .array => p.a.array(p.withPackIfDefault(t.elem, pk), t.len),
            else => ty,
        };
    }

    fn globalVars(p: *Parser, base: u32, flags: u32, first_name: Token) void {
        var name = first_name;
        while (true) {
            const ty = p.arrayDims(base) orelse return;
            const static_ = flags & ast.F_STATIC != 0;
            const t = p.a.types[ty];
            const object = t.class == .texture or t.class == .sampler or t.class == .rwtexture or t.class == .sbuffer or (t.class == .array and p.isObject(ty));
            const storage: ast.Storage = if (flags & ast.F_GROUPSHARED != 0) .groupshared else if (static_ and !object) .static_global else .global;
            const s = p.newSym(.{ .kind = .variable, .storage = storage, .name_off = name.off, .name_len = name.len, .ty = p.packTy(ty, flags), .flags = flags, .line = name.line() });
            var sem: [2]u32 = undefined;
            if (!p.postfixDecl(s, &sem)) return;
            if (p.accept(.assign)) {
                const init = p.initializer();
                p.a.syms[s].init = init;
                p.sizeFromInit(s, init);
            }
            p.declare(s);
            p.addGlobal(s);
            if (!p.accept(.comma)) break;
            name = p.expectIdent() orelse return;
        }
        _ = p.expect(.semicolon);
    }

    pub fn isObject(p: *const Parser, ty: u32) bool {
        var t = p.a.types[ty];
        while (t.class == .array) t = p.a.types[t.elem];
        return t.class == .texture or t.class == .sampler or t.class == .rwtexture or t.class == .sbuffer or t.class == .stream;
    }

    /// `: SEMANTIC`, `: register(...)`, `: packoffset(...)`, annotations.
    fn postfixDecl(p: *Parser, s: u32, _: *[2]u32) bool {
        while (true) {
            if (p.peek() == .lt) {
                // an annotation block <...>: skipped
                var depth: u32 = 0;
                while (p.peek() != .eof) {
                    const k = p.advance().kind;
                    if (k == .lt) depth += 1;
                    if (k == .gt) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                continue;
            }
            if (!p.accept(.colon)) return true;
            const w = p.expectIdent() orelse return false;
            const ws = p.text(w);
            if (std.mem.eql(u8, ws, "register")) {
                if (!p.expect(.lparen)) return false;
                // (a profile first: register(ps, s0))
                if (p.peek() == .ident and p.peekAt(1) == .comma and !regToken(p.cur())) {
                    _ = p.advance();
                    _ = p.advance();
                }
                const r = p.expectIdent() orelse return false;
                const rs = p.text(r);
                var idx: u32 = 0;
                var j: usize = 1;
                while (j < rs.len and std.ascii.isDigit(rs[j])) : (j += 1) idx = idx * 10 + (rs[j] - '0');
                // register(c[4]) style
                if (p.accept(.lbracket)) {
                    const e = p.assignment();
                    idx = @intCast(@max(p.constInt(e) orelse 0, 0));
                    if (!p.expect(.rbracket)) return false;
                }
                p.a.syms[s].reg_kind = std.ascii.toLower(rs[0]);
                p.a.syms[s].reg_index = idx;
                // (a space: register(t0, space1), accepted)
                if (p.accept(.comma)) _ = p.advance();
                if (!p.expect(.rparen)) return false;
            } else if (std.mem.eql(u8, ws, "packoffset")) {
                if (!p.expect(.lparen)) return false;
                const r = p.expectIdent() orelse return false;
                const rs = p.text(r);
                var idx: u32 = 0;
                var j: usize = 1;
                while (j < rs.len and std.ascii.isDigit(rs[j])) : (j += 1) idx = idx * 10 + (rs[j] - '0');
                var comp: u32 = 0;
                if (p.accept(.dot)) {
                    const c = p.expectIdent() orelse return false;
                    comp = switch (p.text(c)[0]) {
                        'x', 'r' => 0,
                        'y', 'g' => 1,
                        'z', 'b' => 2,
                        'w', 'a' => 3,
                        else => 0,
                    };
                }
                // (packoffset(c3.z) can also lex as c3 . z, or c3.z as a float? no: c3 is a name)
                p.a.syms[s].packoffset = idx * 16 + comp * 4;
                if (!p.expect(.rparen)) return false;
            } else {
                // a semantic: its name and index (the trailing digits)
                var n = ws.len;
                while (n > 0 and std.ascii.isDigit(ws[n - 1])) n -= 1;
                var idx: u32 = 0;
                for (ws[n..]) |ch| idx = idx * 10 + (ch - '0');
                p.a.syms[s].sem_off = w.off;
                p.a.syms[s].sem_len = @intCast(n);
                p.a.syms[s].sem_index = idx;
            }
        }
    }

    fn regToken(s: []const u8) bool {
        if (s.len < 2) return false;
        const c = std.ascii.toLower(s[0]);
        if (c != 'b' and c != 't' and c != 's' and c != 'c' and c != 'u') return false;
        for (s[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
        return true;
    }

    fn function(p: *Parser, ret: u32, flags: u32, name: Token, max_vertex: u32) void {
        const prev = p.lookup(p.text(name));
        const f = p.newSym(.{ .kind = .function, .name_off = name.off, .name_len = name.len, .ty = ret, .flags = flags, .prev = if (prev) |x| (if (p.a.syms[x].kind == .function) x else NONE) else NONE, .max_vertex = max_vertex, .line = name.line() });
        _ = p.advance(); // (
        p.pushScope();
        defer p.popScope();
        p.a.syms[f].params = p.a.nsyms;
        var np: u32 = 0;
        if (!(p.peek() == .ident and p.curIs("void") and p.peekAt(1) == .rparen)) {
            while (p.peek() != .rparen and p.peek() != .eof and !p.failed) {
                var pf: u32 = 0;
                const pty = p.typeSpec(&pf, true) orelse return;
                const pn = p.expectIdent() orelse return;
                const ty = p.arrayDims(pty) orelse return;
                if (pf & (ast.F_IN | ast.F_OUT) == 0) pf |= ast.F_IN;
                const ps = p.newSym(.{ .kind = .variable, .storage = .param, .name_off = pn.off, .name_len = pn.len, .ty = p.packTy(ty, pf), .flags = pf, .line = pn.line() });
                var sem: [2]u32 = undefined;
                if (!p.postfixDecl(ps, &sem)) return;
                if (p.accept(.assign)) p.a.syms[ps].init = p.assignment();
                p.declare(ps);
                np += 1;
                if (!p.accept(.comma)) break;
            }
        } else _ = p.advance();
        if (!p.expect(.rparen)) return;
        p.a.syms[f].nparams = np;
        // the function's own name is visible in its body (and after)
        p.scopeDeclareOuter(f);
        var sem: [2]u32 = undefined;
        if (!p.postfixDecl(f, &sem)) return;
        if (p.accept(.semicolon)) {
            p.addGlobal(f);
            return;
        }
        if (p.peek() != .lbrace) return p.fail("syntax error: function body expected", .{});
        p.a.syms[f].flags |= ast.F_DEFINED;
        p.addGlobal(f);
        const was = p.in_function;
        p.in_function = true;
        defer p.in_function = was;
        p.a.syms[f].body = p.block();
    }

    /// Declares `s` in the scope enclosing the current one (a function's
    /// name, from inside its parameter scope).
    fn scopeDeclareOuter(p: *Parser, s: u32) void {
        if (p.nmarks == 0) return p.declare(s);
        const at = p.marks[p.nmarks - 1];
        if (p.nscope >= MAX_SCOPE) return;
        // shift the parameters up one
        var i = p.nscope;
        while (i > at) : (i -= 1) p.scope[i] = p.scope[i - 1];
        p.scope[at] = s;
        p.nscope += 1;
        p.marks[p.nmarks - 1] = at + 1;
    }

    // ── types ──

    const Mod = struct { s: []const u8, f: u32 };
    const modifiers = [_]Mod{
        .{ .s = "const", .f = ast.F_CONST },
        .{ .s = "static", .f = ast.F_STATIC },
        .{ .s = "uniform", .f = ast.F_UNIFORM },
        .{ .s = "extern", .f = ast.F_EXTERN },
        .{ .s = "volatile", .f = 0 },
        .{ .s = "shared", .f = 0 },
        .{ .s = "groupshared", .f = ast.F_GROUPSHARED },
        .{ .s = "precise", .f = ast.F_PRECISE },
        .{ .s = "inline", .f = ast.F_INLINE },
        .{ .s = "in", .f = ast.F_IN },
        .{ .s = "out", .f = ast.F_OUT },
        .{ .s = "inout", .f = ast.F_IN | ast.F_OUT },
        .{ .s = "row_major", .f = ast.F_ROW_MAJOR },
        .{ .s = "column_major", .f = ast.F_COL_MAJOR },
        .{ .s = "nointerpolation", .f = ast.F_NOINTERP },
        .{ .s = "linear", .f = ast.F_LINEAR },
        .{ .s = "centroid", .f = ast.F_CENTROID },
        .{ .s = "noperspective", .f = ast.F_NOPERSP },
        .{ .s = "sample", .f = ast.F_SAMPLE },
        .{ .s = "unorm", .f = 0 },
        .{ .s = "snorm", .f = 0 },
        .{ .s = "globallycoherent", .f = 0 },
        .{ .s = "point", .f = ast.F_GS_POINT },
        .{ .s = "line", .f = ast.F_GS_LINE },
        .{ .s = "triangle", .f = ast.F_GS_TRIANGLE },
        .{ .s = "lineadj", .f = ast.F_GS_LINEADJ },
        .{ .s = "triangleadj", .f = ast.F_GS_TRIADJ },
    };

    fn modifier(s: []const u8) ?u32 {
        for (modifiers) |m| if (std.mem.eql(u8, m.s, s)) return m.f;
        return null;
    }

    /// Whether the tokens at the cursor start a type (for casts and
    /// declarations).
    pub fn startsType(p: *Parser) bool {
        if (p.peek() != .ident) return false;
        const s = p.cur();
        if (modifier(s) != null) {
            // ("in", "point", "line", "sample"... are also names: a modifier
            // only when another word follows)
            return p.peekAt(1) == .ident;
        }
        if (std.mem.eql(u8, s, "struct")) return true;
        if (builtinType(p, s, false) != null) return true;
        if (p.lookup(s)) |sym| return p.a.syms[sym].kind == .typename;
        return false;
    }

    /// Modifiers, then a type: a built-in, a struct (declared here or by
    /// name), a typedef's.
    pub fn typeSpec(p: *Parser, flags: *u32, allow_struct: bool) ?u32 {
        while (p.peek() == .ident) {
            const s = p.cur();
            const f = modifier(s) orelse break;
            // a name, not a modifier, when it is the declarator itself
            if (p.peekAt(1) != .ident) break;
            flags.* |= f;
            _ = p.advance();
        }
        if (p.peek() != .ident) {
            p.fail("syntax error: a type expected, found '{s}'", .{p.cur()});
            return null;
        }
        if (p.curIs("struct")) {
            if (!allow_struct) {
                p.fail("a struct cannot be declared here", .{});
                return null;
            }
            return p.structDecl();
        }
        const s = p.cur();
        if (builtinType(p, s, true)) |ty| return ty;
        if (p.lookup(s)) |sym| {
            if (p.a.syms[sym].kind == .typename) {
                _ = p.advance();
                return p.a.syms[sym].ty;
            }
        }
        p.fail("unknown type '{s}'", .{s});
        return null;
    }

    fn structDecl(p: *Parser) ?u32 {
        _ = p.advance(); // struct
        var name_off: u32 = 0;
        var name_len: u16 = 0;
        if (p.peek() == .ident) {
            const n = p.advance();
            name_off = n.off;
            name_len = n.len;
            if (p.peek() != .lbrace) {
                // a use of a struct declared earlier
                if (p.lookup(p.text(n))) |sym| {
                    if (p.a.syms[sym].kind == .typename) return p.a.syms[sym].ty;
                }
                p.fail("unknown struct '{s}'", .{p.text(n)});
                return null;
            }
        }
        if (!p.expect(.lbrace)) return null;
        if (p.a.ntypes >= ast.MAX_TYPES) {
            p.fail("too many types", .{});
            return null;
        }
        const ty = p.a.ntypes;
        p.a.types[ty] = .{ .class = .structure, .first = p.a.nmembers, .name_off = name_off, .name_len = name_len };
        p.a.ntypes += 1;
        // (the name is visible inside, for nothing but errors; declared now)
        if (name_len > 0) {
            const s = p.newSym(.{ .kind = .typename, .name_off = name_off, .name_len = name_len, .ty = ty });
            p.declare(s);
        }
        var count: u32 = 0;
        while (p.peek() != .rbrace and p.peek() != .eof and !p.failed) {
            if (p.accept(.semicolon)) continue;
            var flags: u32 = 0;
            const mty = p.typeSpec(&flags, true) orelse return null;
            while (true) {
                const mn = p.expectIdent() orelse return null;
                const full = p.arrayDims(mty) orelse return null;
                if (p.a.nmembers >= ast.MAX_MEMBERS) {
                    p.fail("too many struct members", .{});
                    return null;
                }
                // a scratch symbol takes the semantic
                var tmp = ast.Sym{ .kind = .variable };
                const save = p.a.syms[0];
                p.a.syms[0] = tmp;
                var sem: [2]u32 = undefined;
                if (!p.postfixDecl(0, &sem)) return null;
                tmp = p.a.syms[0];
                p.a.syms[0] = save;
                p.a.members[p.a.nmembers] = .{ .name_off = mn.off, .name_len = mn.len, .ty = p.packTy(full, flags), .sem_off = tmp.sem_off, .sem_len = tmp.sem_len, .sem_index = tmp.sem_index, .flags = flags & ast.INTERP };
                p.a.nmembers += 1;
                count += 1;
                if (!p.accept(.comma)) break;
            }
            if (!p.expect(.semicolon)) return null;
        }
        if (!p.expect(.rbrace)) return null;
        p.a.types[ty].len = count;
        return ty;
    }

    /// Trailing `[N]...` on a declarator: the array type (the first
    /// dimension outermost). `[]` takes its size from an initializer later
    /// (len 0).
    fn arrayDims(p: *Parser, base: u32) ?u32 {
        var dims: [8]u32 = undefined;
        var n: usize = 0;
        while (p.accept(.lbracket)) {
            var len: u32 = 0;
            if (p.peek() != .rbracket) {
                const e = p.assignment();
                const v = p.constInt(e) orelse {
                    p.fail("array dimensions must be literal scalar expressions", .{});
                    return null;
                };
                if (v <= 0) {
                    p.fail("array dimension must be between 1 and 65536", .{});
                    return null;
                }
                len = @intCast(v);
            }
            if (!p.expect(.rbracket)) return null;
            if (n < dims.len) {
                dims[n] = len;
                n += 1;
            }
        }
        var ty = base;
        while (n > 0) {
            n -= 1;
            ty = p.a.array(ty, dims[n]);
        }
        return ty;
    }

    // ── statements ──

    fn block(p: *Parser) u32 {
        const b = p.newNode(.block);
        if (!p.expect(.lbrace)) return b;
        p.pushScope();
        defer p.popScope();
        var last: u32 = NONE;
        while (p.peek() != .rbrace and p.peek() != .eof and !p.failed) {
            const s = p.statement();
            if (s == NONE) continue;
            // (a declaration may make several nodes: find their end)
            if (last == NONE) p.a.nodes[b].a = s else p.a.nodes[last].next = s;
            last = s;
            while (p.a.nodes[last].next != NONE) last = p.a.nodes[last].next;
        }
        _ = p.expect(.rbrace);
        return b;
    }

    fn statement(p: *Parser) u32 {
        var attr: u8 = 0;
        while (p.peek() == .lbracket) {
            _ = p.advance();
            const name = p.expectIdent() orelse return NONE;
            const s = p.text(name);
            if (std.mem.eql(u8, s, "loop")) attr |= ast.A_LOOP;
            if (std.mem.eql(u8, s, "unroll")) attr |= ast.A_UNROLL;
            if (std.mem.eql(u8, s, "branch")) attr |= ast.A_BRANCH;
            if (std.mem.eql(u8, s, "flatten")) attr |= ast.A_FLATTEN;
            if (std.mem.eql(u8, s, "fastopt")) attr |= ast.A_FASTOPT;
            if (std.mem.eql(u8, s, "forcecase")) attr |= ast.A_FORCECASE;
            if (p.accept(.lparen)) {
                while (p.peek() != .rparen and p.peek() != .eof) _ = p.advance();
                if (!p.expect(.rparen)) return NONE;
            }
            if (!p.expect(.rbracket)) return NONE;
        }
        const k = p.peek();
        if (k == .lbrace) return p.block();
        if (k == .semicolon) {
            _ = p.advance();
            return p.newNode(.empty);
        }
        if (k == .ident) {
            const s = p.cur();
            if (std.mem.eql(u8, s, "if")) return p.ifStmt(attr);
            if (std.mem.eql(u8, s, "for")) return p.forStmt(attr);
            if (std.mem.eql(u8, s, "while")) return p.whileStmt(attr);
            if (std.mem.eql(u8, s, "do")) return p.doStmt(attr);
            if (std.mem.eql(u8, s, "switch")) return p.switchStmt(attr);
            if (std.mem.eql(u8, s, "return")) {
                const n = p.newNode(.return_);
                _ = p.advance();
                if (p.peek() != .semicolon) p.a.nodes[n].a = p.expression();
                _ = p.expect(.semicolon);
                return n;
            }
            if (std.mem.eql(u8, s, "break") or std.mem.eql(u8, s, "continue") or std.mem.eql(u8, s, "discard")) {
                const n = p.newNode(if (s[0] == 'b') .break_ else if (s[0] == 'c') .continue_ else .discard_);
                _ = p.advance();
                _ = p.expect(.semicolon);
                return n;
            }
            if (std.mem.eql(u8, s, "case")) {
                const n = p.newNode(.case_);
                _ = p.advance();
                p.a.nodes[n].a = p.ternary();
                _ = p.expect(.colon);
                return n;
            }
            if (std.mem.eql(u8, s, "default") and p.peekAt(1) == .colon) {
                const n = p.newNode(.default_);
                _ = p.advance();
                _ = p.advance();
                return n;
            }
            if (std.mem.eql(u8, s, "typedef")) {
                p.typedef();
                return NONE;
            }
            if (p.startsType() and !(p.peekAt(1) == .lparen and !p.curIs("struct") and modifier(s) == null)) return p.localDecl();
        }
        const n = p.newNode(.expr);
        p.a.nodes[n].a = p.expression();
        _ = p.expect(.semicolon);
        return n;
    }

    /// `T a = x, b[2];`: one decl node per variable, chained by `next`.
    fn localDecl(p: *Parser) u32 {
        var flags: u32 = 0;
        const base = p.typeSpec(&flags, true) orelse return NONE;
        if (p.accept(.semicolon)) return NONE; // (a struct declared alone)
        var first: u32 = NONE;
        var last: u32 = NONE;
        while (true) {
            const name = p.expectIdent() orelse return NONE;
            var ty = p.arrayDims(base) orelse return NONE;
            const storage: ast.Storage = if (flags & ast.F_STATIC != 0) .static_global else .local;
            const s = p.newSym(.{ .kind = .variable, .storage = storage, .name_off = name.off, .name_len = name.len, .ty = ty, .flags = flags, .line = name.line() });
            var sem: [2]u32 = undefined;
            if (!p.postfixDecl(s, &sem)) return NONE;
            if (p.accept(.assign)) {
                const init = p.initializer();
                p.a.syms[s].init = init;
                p.sizeFromInit(s, init);
                ty = p.a.syms[s].ty;
            }
            p.declare(s);
            const d = p.newNode(.decl);
            p.a.nodes[d].a = s;
            if (first == NONE) first = d else p.a.nodes[last].next = d;
            last = d;
            if (!p.accept(.comma)) break;
        }
        _ = p.expect(.semicolon);
        return first;
    }

    /// T a[] = {...}: the length from the initializer.
    fn sizeFromInit(p: *Parser, s: u32, init: u32) void {
        const ty = p.a.syms[s].ty;
        if (p.a.types[ty].class != .array or p.a.types[ty].len != 0 or p.a.nodes[init].kind != .init_list) return;
        const et = p.a.types[ty].elem;
        // (elements given as nested lists, or as scalars)
        const n = p.a.nodes[init].c;
        var nested = true;
        var e = p.a.nodes[init].a;
        while (e != NONE) : (e = p.a.nodes[e].next) nested = nested and p.a.nodes[e].kind == .init_list;
        const len = if (nested or p.a.comps(et) == 1) n else blk: {
            // constructors count one element each; bare scalars by components
            var any_scalar = false;
            e = p.a.nodes[init].a;
            while (e != NONE) : (e = p.a.nodes[e].next) any_scalar = any_scalar or p.a.nodes[e].kind == .lit_float or p.a.nodes[e].kind == .lit_int;
            break :blk if (any_scalar) p.listComps(init) / @max(p.a.comps(et), 1) else n;
        };
        p.a.syms[s].ty = p.a.array(et, len);
    }

    /// The scalars an initializer list holds (nested lists flattened;
    /// elements counted as single values here, the generator checks).
    fn listComps(p: *Parser, n: u32) u32 {
        var c: u32 = 0;
        var e = p.a.nodes[n].a;
        while (e != NONE) : (e = p.a.nodes[e].next) {
            c += if (p.a.nodes[e].kind == .init_list) p.listComps(e) else 1;
        }
        return c;
    }

    fn initializer(p: *Parser) u32 {
        if (p.peek() != .lbrace) return p.assignment();
        const n = p.newNode(.init_list);
        _ = p.advance();
        var last: u32 = NONE;
        var count: u32 = 0;
        while (p.peek() != .rbrace and p.peek() != .eof and !p.failed) {
            const e = p.initializer();
            if (last == NONE) p.a.nodes[n].a = e else p.a.nodes[last].next = e;
            last = e;
            count += 1;
            if (!p.accept(.comma)) break;
        }
        _ = p.expect(.rbrace);
        p.a.nodes[n].c = count;
        return n;
    }

    fn ifStmt(p: *Parser, attr: u8) u32 {
        const n = p.newNode(.if_);
        p.a.nodes[n].attr = attr;
        _ = p.advance();
        if (!p.expect(.lparen)) return n;
        p.a.nodes[n].a = p.expression();
        if (!p.expect(.rparen)) return n;
        p.a.nodes[n].b = p.scoped();
        if (p.acceptWord("else")) p.a.nodes[n].c = p.scoped();
        return n;
    }

    /// A statement in a scope of its own (an if's or a loop's body).
    fn scoped(p: *Parser) u32 {
        p.pushScope();
        defer p.popScope();
        const s = p.statement();
        if (s != NONE and p.a.nodes[s].next != NONE) {
            // several declarations: wrap them in a block
            const b = p.newNode(.block);
            p.a.nodes[b].a = s;
            return b;
        }
        return if (s == NONE) p.newNode(.empty) else s;
    }

    fn forStmt(p: *Parser, attr: u8) u32 {
        const n = p.newNode(.for_);
        p.a.nodes[n].attr = attr;
        _ = p.advance();
        if (!p.expect(.lparen)) return n;
        // (the init's variables stay visible after the loop, as fxc's do)
        if (p.peek() != .semicolon) {
            if (p.startsType()) {
                const d = p.localDecl();
                if (d != NONE and p.a.nodes[d].next != NONE) {
                    const b = p.newNode(.block);
                    p.a.nodes[b].a = d;
                    p.a.nodes[n].a = b;
                } else p.a.nodes[n].a = d;
            } else {
                const e = p.newNode(.expr);
                p.a.nodes[e].a = p.expression();
                p.a.nodes[n].a = e;
                if (!p.expect(.semicolon)) return n;
            }
        } else _ = p.advance();
        if (p.peek() != .semicolon) p.a.nodes[n].b = p.expression();
        if (!p.expect(.semicolon)) return n;
        if (p.peek() != .rparen) p.a.nodes[n].c = p.expression();
        if (!p.expect(.rparen)) return n;
        p.a.nodes[n].d = p.scoped();
        return n;
    }

    fn whileStmt(p: *Parser, attr: u8) u32 {
        const n = p.newNode(.while_);
        p.a.nodes[n].attr = attr;
        _ = p.advance();
        if (!p.expect(.lparen)) return n;
        p.a.nodes[n].a = p.expression();
        if (!p.expect(.rparen)) return n;
        p.a.nodes[n].d = p.scoped();
        return n;
    }

    fn doStmt(p: *Parser, attr: u8) u32 {
        const n = p.newNode(.do_);
        p.a.nodes[n].attr = attr;
        _ = p.advance();
        p.a.nodes[n].d = p.scoped();
        if (!p.acceptWord("while")) {
            p.fail("syntax error: 'while' expected", .{});
            return n;
        }
        if (!p.expect(.lparen)) return n;
        p.a.nodes[n].a = p.expression();
        if (!p.expect(.rparen)) return n;
        _ = p.expect(.semicolon);
        return n;
    }

    fn switchStmt(p: *Parser, attr: u8) u32 {
        const n = p.newNode(.switch_);
        p.a.nodes[n].attr = attr;
        _ = p.advance();
        if (!p.expect(.lparen)) return n;
        p.a.nodes[n].a = p.expression();
        if (!p.expect(.rparen)) return n;
        if (p.peek() != .lbrace) {
            p.fail("syntax error: '{{' expected after switch", .{});
            return n;
        }
        p.a.nodes[n].b = p.block();
        return n;
    }

    // ── expressions ──

    pub fn expression(p: *Parser) u32 {
        var l = p.assignment();
        while (p.peek() == .comma) {
            const n = p.newNode(.comma);
            _ = p.advance();
            p.a.nodes[n].a = l;
            p.a.nodes[n].b = p.assignment();
            l = n;
        }
        return l;
    }

    fn isAssignOp(k: Kind) bool {
        return switch (k) {
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign, .shl_assign, .shr_assign, .and_assign, .xor_assign, .or_assign => true,
            else => false,
        };
    }

    pub fn assignment(p: *Parser) u32 {
        const l = p.ternary();
        if (isAssignOp(p.peek())) {
            const n = p.newNode(.assign);
            p.a.nodes[n].op = @intFromEnum(p.advance().kind);
            p.a.nodes[n].a = l;
            p.a.nodes[n].b = p.assignment();
            p.markAssigned(l);
            return n;
        }
        return l;
    }

    /// The variable an lvalue writes (through members, indices, swizzles).
    pub fn markAssigned(p: *Parser, e: u32) void {
        var x = e;
        while (x != NONE) {
            const n = p.a.nodes[x];
            switch (n.kind) {
                .ident => {
                    p.a.syms[n.a].flags |= ast.F_ASSIGNED;
                    return;
                },
                .member, .index => x = n.a,
                .cast => x = n.b,
                else => return,
            }
        }
    }

    pub fn ternary(p: *Parser) u32 {
        const c = p.binary(0);
        if (p.peek() == .question) {
            const n = p.newNode(.ternary);
            _ = p.advance();
            p.a.nodes[n].a = c;
            p.a.nodes[n].b = p.assignment();
            if (!p.expect(.colon)) return n;
            p.a.nodes[n].c = p.assignment();
            return n;
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

    fn binary(p: *Parser, min: u8) u32 {
        var l = p.unary();
        while (true) {
            const k = p.peek();
            const pr = prec(k);
            if (pr == 0 or pr <= min) break;
            const n = p.newNode(.binary);
            _ = p.advance();
            p.a.nodes[n].op = @intFromEnum(k);
            p.a.nodes[n].a = l;
            p.a.nodes[n].b = p.binary(pr);
            l = n;
        }
        return l;
    }

    fn unary(p: *Parser) u32 {
        const k = p.peek();
        switch (k) {
            .minus, .plus, .bang, .tilde => {
                const n = p.newNode(.unary);
                _ = p.advance();
                p.a.nodes[n].op = @intFromEnum(k);
                p.a.nodes[n].a = p.unary();
                return n;
            },
            .inc, .dec => {
                const n = p.newNode(if (k == .inc) .preinc else .predec);
                _ = p.advance();
                p.a.nodes[n].a = p.unary();
                p.markAssigned(p.a.nodes[n].a);
                return n;
            },
            .lparen => {
                // a cast: (type) or (type[N])
                const save = p.at;
                _ = p.advance();
                if (p.startsType()) {
                    var flags: u32 = 0;
                    const ty0 = p.typeSpec(&flags, false) orelse return NONE;
                    const ty = p.arrayDims(ty0) orelse return NONE;
                    if (p.accept(.rparen)) {
                        const n = p.newNode(.cast);
                        p.a.nodes[n].a = ty;
                        p.a.nodes[n].b = p.unary();
                        return n;
                    }
                }
                p.at = save;
            },
            else => {},
        }
        return p.postfix(p.primary());
    }

    fn postfix(p: *Parser, e0: u32) u32 {
        var e = e0;
        while (!p.failed) {
            switch (p.peek()) {
                .lbracket => {
                    const n = p.newNode(.index);
                    _ = p.advance();
                    p.a.nodes[n].a = e;
                    p.a.nodes[n].b = p.expression();
                    if (!p.expect(.rbracket)) return n;
                    e = n;
                },
                .dot => {
                    _ = p.advance();
                    const at: u32 = @intCast(p.at);
                    const name = p.expectIdent() orelse return e;
                    _ = name;
                    if (p.peek() == .lparen) {
                        const n = p.newNode(.method);
                        p.a.nodes[n].tok = at;
                        p.a.nodes[n].a = e;
                        _ = p.advance();
                        const args = p.argList();
                        p.a.nodes[n].b = args[0];
                        p.a.nodes[n].c = args[1];
                        e = n;
                    } else {
                        const n = p.newNode(.member);
                        p.a.nodes[n].tok = at;
                        p.a.nodes[n].a = e;
                        e = n;
                    }
                },
                .inc, .dec => {
                    const n = p.newNode(if (p.peek() == .inc) .postinc else .postdec);
                    _ = p.advance();
                    p.a.nodes[n].a = e;
                    p.markAssigned(e);
                    e = n;
                },
                else => return e,
            }
        }
        return e;
    }

    /// After '(': arguments to ')'; (first, count).
    fn argList(p: *Parser) [2]u32 {
        var first: u32 = NONE;
        var last: u32 = NONE;
        var count: u32 = 0;
        while (p.peek() != .rparen and p.peek() != .eof and !p.failed) {
            const e = p.assignment();
            if (last == NONE) first = e else p.a.nodes[last].next = e;
            last = e;
            count += 1;
            if (!p.accept(.comma)) break;
        }
        _ = p.expect(.rparen);
        return .{ first, count };
    }

    fn primary(p: *Parser) u32 {
        const t = p.tok();
        switch (t.kind) {
            .int_lit => {
                const n = p.newNode(.lit_int);
                _ = p.advance();
                var u = false;
                const v = lex.intValue(p.text(t), &u);
                p.a.nodes[n].a = @truncate(v);
                p.a.nodes[n].b = @truncate(v >> 32);
                if (u) p.a.nodes[n].op = ast.LIT_UNSIGNED;
                return n;
            },
            .float_lit => {
                const n = p.newNode(.lit_float);
                _ = p.advance();
                const v: f32 = @floatCast(lex.floatValue(p.text(t)));
                p.a.nodes[n].a = @bitCast(v);
                return n;
            },
            .lparen => {
                _ = p.advance();
                const e = p.expression();
                _ = p.expect(.rparen);
                return e;
            },
            .lbrace => return p.initializer(),
            .ident => {},
            else => {
                p.fail("syntax error: unexpected '{s}'", .{if (t.kind == .eof) "end of file" else p.text(t)});
                return NONE;
            },
        }
        const s = p.text(t);
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) {
            const n = p.newNode(.lit_bool);
            _ = p.advance();
            p.a.nodes[n].a = @intFromBool(s[0] == 't');
            return n;
        }
        // a constructor: a built-in type and '('
        if (p.peekAt(1) == .lparen or p.peekAt(1) == .lt) {
            const save = p.at;
            if (builtinType(p, s, false) != null and !(p.lookup(s) != null and p.a.syms[p.lookup(s).?].kind == .function)) {
                const ty = builtinType(p, s, true) orelse return NONE;
                if (p.peek() == .lparen) {
                    const n = p.newNode(.construct);
                    _ = p.advance();
                    const args = p.argList();
                    p.a.nodes[n].a = ty;
                    p.a.nodes[n].b = args[0];
                    p.a.nodes[n].c = args[1];
                    return n;
                }
                p.at = save;
            }
        }
        if (p.peekAt(1) == .lparen) {
            // a call: a function's newest declaration, or an intrinsic
            const n = p.newNode(.call);
            _ = p.advance();
            _ = p.advance();
            const f = p.lookup(s);
            if (f) |x| {
                if (p.a.syms[x].kind == .typename) {
                    // a typedef'd type's constructor
                    const args = p.argList();
                    p.a.nodes[n].kind = .construct;
                    p.a.nodes[n].a = p.a.syms[x].ty;
                    p.a.nodes[n].b = args[0];
                    p.a.nodes[n].c = args[1];
                    return n;
                }
                if (p.a.syms[x].kind == .function) p.a.nodes[n].d = x;
            }
            const args = p.argList();
            p.a.nodes[n].a = args[0];
            p.a.nodes[n].c = args[1];
            return n;
        }
        const sym = p.lookup(s) orelse {
            p.fail("undeclared identifier '{s}'", .{s});
            return NONE;
        };
        const n = p.newNode(.ident);
        _ = p.advance();
        p.a.nodes[n].a = sym;
        return n;
    }

    // ── constant integers (array sizes, attributes) ──

    pub fn constInt(p: *Parser, e: u32) ?i64 {
        if (e == NONE) return null;
        const n = p.a.nodes[e];
        return switch (n.kind) {
            .lit_int => @as(i64, @intCast(@as(u64, n.b) << 32 | n.a)),
            .lit_float => @intFromFloat(@as(f32, @bitCast(n.a))),
            .lit_bool => n.a,
            .ident => blk: {
                const s = p.a.syms[n.a];
                if (s.flags & ast.F_CONST == 0 or s.init == NONE) break :blk null;
                break :blk p.constInt(s.init);
            },
            .cast, .construct => if (n.kind == .cast) p.constInt(n.b) else (if (n.c == 1) p.constInt(n.b) else null),
            .unary => blk: {
                const v = p.constInt(n.a) orelse break :blk null;
                break :blk switch (@as(Kind, @enumFromInt(n.op))) {
                    .minus => -v,
                    .plus => v,
                    .tilde => ~v,
                    .bang => @intFromBool(v == 0),
                    else => null,
                };
            },
            .binary => blk: {
                const l = p.constInt(n.a) orelse break :blk null;
                const r = p.constInt(n.b) orelse break :blk null;
                break :blk switch (@as(Kind, @enumFromInt(n.op))) {
                    .plus => l + r,
                    .minus => l - r,
                    .star => l * r,
                    .slash => if (r == 0) null else @divTrunc(l, r),
                    .percent => if (r == 0) null else @rem(l, r),
                    .shl => l << @intCast(r & 63),
                    .shr => l >> @intCast(r & 63),
                    .amp => l & r,
                    .pipe => l | r,
                    .caret => l ^ r,
                    .lt => @intFromBool(l < r),
                    .gt => @intFromBool(l > r),
                    .le => @intFromBool(l <= r),
                    .ge => @intFromBool(l >= r),
                    .eq => @intFromBool(l == r),
                    .ne => @intFromBool(l != r),
                    .and_and => @intFromBool(l != 0 and r != 0),
                    .or_or => @intFromBool(l != 0 or r != 0),
                    else => null,
                };
            },
            .ternary => blk: {
                const c = p.constInt(n.a) orelse break :blk null;
                break :blk if (c != 0) p.constInt(n.b) else p.constInt(n.c);
            },
            else => null,
        };
    }
};

// ── built-in type names ────────────────────────────────────────────────────

const Scalar = struct { s: []const u8, b: ast.Base };
const scalars = [_]Scalar{
    .{ .s = "float", .b = .float },
    .{ .s = "int", .b = .int },
    .{ .s = "uint", .b = .uint },
    .{ .s = "bool", .b = .bool },
    .{ .s = "half", .b = .half },
    .{ .s = "double", .b = .double },
    .{ .s = "dword", .b = .uint },
    .{ .s = "min16float", .b = .min16float },
    .{ .s = "min10float", .b = .min10float },
    .{ .s = "min16int", .b = .min16int },
    .{ .s = "min12int", .b = .min12int },
    .{ .s = "min16uint", .b = .min16uint },
};

const TexName = struct { s: []const u8, d: ast.TexDim };
const textures = [_]TexName{
    .{ .s = "Texture1D", .d = .tex1d },
    .{ .s = "Texture1DArray", .d = .tex1darray },
    .{ .s = "Texture2D", .d = .tex2d },
    .{ .s = "Texture2DArray", .d = .tex2darray },
    .{ .s = "Texture2DMS", .d = .tex2dms },
    .{ .s = "Texture2DMSArray", .d = .tex2dmsarray },
    .{ .s = "Texture3D", .d = .tex3d },
    .{ .s = "TextureCube", .d = .cube },
    .{ .s = "TextureCubeArray", .d = .cubearray },
    .{ .s = "Buffer", .d = .buffer },
    .{ .s = "texture", .d = .unknown },
    .{ .s = "Texture", .d = .unknown },
};

/// A built-in type's id when `s` names one; with `consume`, its tokens
/// (and template arguments) are read.
fn builtinType(p: *Parser, s: []const u8, consume: bool) ?u32 {
    const a = p.a;
    if (std.mem.eql(u8, s, "void")) {
        if (consume) _ = p.advance();
        return 0;
    }
    for (scalars) |sc| {
        if (!std.mem.startsWith(u8, s, sc.s)) continue;
        const rest = s[sc.s.len..];
        if (rest.len == 0) {
            if (consume) _ = p.advance();
            return a.scalar(sc.b);
        }
        if (rest.len == 1 and rest[0] >= '1' and rest[0] <= '4') {
            if (consume) _ = p.advance();
            return a.vector(sc.b, rest[0] - '0');
        }
        if (rest.len == 3 and rest[1] == 'x' and rest[0] >= '1' and rest[0] <= '4' and rest[2] >= '1' and rest[2] <= '4') {
            if (consume) _ = p.advance();
            return a.matrix(sc.b, rest[0] - '0', rest[2] - '0', .default);
        }
    }
    if (std.mem.eql(u8, s, "vector") or std.mem.eql(u8, s, "matrix")) {
        const mat = s[0] == 'm';
        if (!consume) return a.scalar(.float);
        _ = p.advance();
        if (!p.accept(.lt)) return if (mat) a.matrix(.float, 4, 4, .default) else a.vector(.float, 4);
        var fl: u32 = 0;
        const et = p.typeSpec(&fl, false) orelse return null;
        const b = a.types[et].base;
        _ = p.expect(.comma);
        const r = p.constInt(ternaryNoGt(p)) orelse 4;
        var c: i64 = 1;
        if (mat) {
            _ = p.expect(.comma);
            c = p.constInt(ternaryNoGt(p)) orelse 4;
        }
        _ = p.expect(.gt);
        if (mat) return a.matrix(b, @intCast(r), @intCast(c), .default);
        return a.vector(b, @intCast(r));
    }
    if (std.mem.eql(u8, s, "SamplerState") or std.mem.eql(u8, s, "sampler") or std.mem.eql(u8, s, "sampler1D") or std.mem.eql(u8, s, "sampler2D") or std.mem.eql(u8, s, "sampler3D") or std.mem.eql(u8, s, "samplerCUBE") or std.mem.eql(u8, s, "sampler_state")) {
        if (consume) _ = p.advance();
        return a.intern(.{ .class = .sampler });
    }
    if (std.mem.eql(u8, s, "SamplerComparisonState")) {
        if (consume) _ = p.advance();
        return a.intern(.{ .class = .sampler, .dim = 1 });
    }
    if (std.mem.eql(u8, s, "string")) {
        if (consume) _ = p.advance();
        return a.intern(.{ .class = .string });
    }
    for (textures) |tx| {
        if (!std.mem.eql(u8, s, tx.s)) continue;
        if (!consume) return a.scalar(.float);
        _ = p.advance();
        var ret = a.vector(.float, 4);
        var samples: u32 = 0;
        if (p.accept(.lt)) {
            var fl: u32 = 0;
            ret = p.typeSpec(&fl, false) orelse return null;
            if (p.accept(.comma)) samples = @intCast(@max(p.constInt(ternaryNoGt(p)) orelse 0, 0));
            _ = p.expect(.gt);
        }
        return a.intern(.{ .class = .texture, .dim = @intFromEnum(tx.d), .elem = ret, .len = samples });
    }
    const rw = std.mem.startsWith(u8, s, "RWTexture") or std.mem.eql(u8, s, "RWBuffer");
    const sb = std.mem.eql(u8, s, "StructuredBuffer") or std.mem.eql(u8, s, "RWStructuredBuffer") or std.mem.eql(u8, s, "ByteAddressBuffer") or std.mem.eql(u8, s, "RWByteAddressBuffer");
    if (rw or sb) {
        if (!consume) return a.scalar(.float);
        _ = p.advance();
        var ret: u32 = a.vector(.float, 4);
        if (p.accept(.lt)) {
            var fl: u32 = 0;
            ret = p.typeSpec(&fl, false) orelse return null;
            _ = p.expect(.gt);
        }
        return a.intern(.{ .class = if (rw) .rwtexture else .sbuffer, .elem = ret });
    }
    const streams = [_][]const u8{ "PointStream", "LineStream", "TriangleStream" };
    for (streams, 0..) |st, k| {
        if (!std.mem.eql(u8, s, st)) continue;
        if (!consume) return a.scalar(.float);
        _ = p.advance();
        var elem: u32 = 0;
        if (p.accept(.lt)) {
            var fl: u32 = 0;
            elem = p.typeSpec(&fl, false) orelse return null;
            _ = p.expect(.gt);
        }
        return a.intern(.{ .class = .stream, .dim = @intCast(k), .elem = elem });
    }
    return null;
}

/// A template argument: a ternary that stops at '>' (not a comparison).
fn ternaryNoGt(p: *Parser) u32 {
    // (template arguments are literals or names in practice)
    const t = p.tok();
    if (t.kind == .int_lit) {
        const n = p.newNode(.lit_int);
        _ = p.advance();
        var u = false;
        p.a.nodes[n].a = @truncate(lex.intValue(p.text(t), &u));
        return n;
    }
    return p.unary();
}

// (Parser's own method, called above as ternaryNoGt(p))
pub const _unused = 0;

comptime {
    _ = ternaryNoGt;
}
