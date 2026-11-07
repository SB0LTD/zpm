//! @zpm/gfxapi glsl/parse — GLSL ES's grammar (1.00 and 3.00) into an AST:
//! nodes in one array, linked by index (children `a` .. `d`, siblings by
//! `next`), each with its line. Declarations (qualifiers, layout,
//! precision, structs, arrays, initializers), functions, every statement,
//! and expressions with GLSL's precedence. The checker (sema.sig) gives
//! the nodes their types.
//!
//! Allocation-free: nodes in the caller's array.

const std = @import("std");
const lex = @import("lex.sig");
const pp = @import("pp.sig");
const Token = lex.Token;
const Kind = lex.Kind;
const Kw = lex.Kw;

pub const N = enum(u8) {
    none,
    // declarations
    root, // a: first declaration
    precision, // tok: the type's token, op: lowp/mediump/highp
    decl, // a: type_spec, b: first declarator (var)
    @"var", // tok: name, a: array size (expr) or 0, b: initializer, flags: qualifiers, value: layout location + 1
    type_spec, // tok: the type keyword or struct name, a: struct_def, b: array size, op: 1 when `[]` (unsized)
    struct_def, // tok: name or 0, a: first member decl
    func, // tok: name, a: return type_spec, b: first param, c: body block (0: prototype)
    param, // tok: name (0: none), a: type_spec, b: array size, flags: in/out/inout/const
    invariant, // tok: the name made invariant
    block_decl, // an interface block (refused by the checker)
    // statements
    block, // a: first statement
    decl_stmt, // a: decl
    expr_stmt, // a: expression
    @"if", // a: cond, b: then, c: else
    @"for", // a: init statement, b: cond, c: step, d: body
    @"while", // a: cond, b: body
    do, // a: body, b: cond
    @"switch", // a: expression, b: block
    case, // a: value
    default,
    @"break",
    @"continue",
    @"return", // a: value
    discard,
    empty,
    // expressions
    ident, // tok
    int_lit, // tok, value
    uint_lit,
    float_lit, // value: f32 bits
    bool_lit, // value
    binary, // op: token kind, a, b
    unary, // op: token kind (plus, minus, bang, tilde)
    pre_inc,
    pre_dec,
    post_inc,
    post_dec,
    assign, // op: token kind (assign, add_assign ...), a: target, b: value
    ternary, // a: cond, b, c
    call, // tok: function name (0 for a constructor), a: type_spec (constructors), b: first argument
    field, // a: the expression, tok: the field or swizzle
    index, // a, b
    sequence, // a, b (the comma operator)
};

/// Qualifier bits of a declaration (var.flags, param.flags).
pub const Q = struct {
    pub const @"const": u16 = 1 << 0;
    pub const in: u16 = 1 << 1;
    pub const out: u16 = 1 << 2;
    pub const uniform: u16 = 1 << 3;
    pub const flat: u16 = 1 << 4;
    pub const smooth: u16 = 1 << 5;
    pub const centroid: u16 = 1 << 6;
    pub const invariant: u16 = 1 << 7;
    pub const inout: u16 = in | out;
    /// 1.00's
    pub const attribute: u16 = 1 << 8;
    pub const varying: u16 = 1 << 9;
    /// a precision said (lowp, mediump, highp)
    pub const precision: u16 = 1 << 10;
};

pub const Node = struct {
    kind: N = .none,
    op: u8 = 0,
    flags: u16 = 0,
    line: u32 = 0,
    tok: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    next: u32 = 0,
    /// the checker's: the type (sema.Type's bits)
    ty: u32 = 0,
    /// a literal's bits, a layout location + 1, a constant's value
    value: u32 = 0,
};

pub const MAX_STRUCT_NAMES = 256;

pub const Parser = struct {
    toks: []Token,
    at: usize = 0,
    nodes: []Node,
    n: u32 = 1,
    log: *pp.Log,
    version: u32,
    struct_names: [MAX_STRUCT_NAMES][]const u8 = undefined,
    nstructs: usize = 0,
    full: bool = false,

    /// Parses the tokens (the last an eof); the root's index, or 0 when
    /// the nodes ran out.
    pub fn run(p: *Parser) u32 {
        for (p.toks) |*t| {
            if (t.kind == .ident) t.kw = lex.keyword(t.text, p.version);
        }
        const root = p.node(.root, p.line());
        var last: u32 = 0;
        while (p.peek().kind != .eof and p.log.errors < 20) {
            const before = p.at;
            const d = p.external();
            if (d != 0) p.link(root, &last, d);
            if (p.at == before) p.at += 1;
        }
        if (p.full) return 0;
        return root;
    }

    // ── Tokens and nodes ───────────────────────────────────────────────────

    fn peek(p: *const Parser) Token {
        return p.toks[@min(p.at, p.toks.len - 1)];
    }
    fn peekAt(p: *const Parser, k: usize) Token {
        return p.toks[@min(p.at + k, p.toks.len - 1)];
    }
    fn line(p: *const Parser) u32 {
        return p.peek().line;
    }
    fn take(p: *Parser) u32 {
        const i = p.at;
        if (p.at < p.toks.len - 1) p.at += 1;
        return @intCast(i);
    }
    fn is(p: *const Parser, k: Kind) bool {
        return p.peek().kind == k;
    }
    fn isKw(p: *const Parser, kw: Kw) bool {
        return p.peek().kind == .ident and p.peek().kw == kw;
    }
    fn accept(p: *Parser, k: Kind) bool {
        if (!p.is(k)) return false;
        _ = p.take();
        return true;
    }
    fn expect(p: *Parser, k: Kind, what: []const u8) bool {
        if (p.accept(k)) return true;
        p.log.err(p.line(), "expected {s}, found `{s}`", .{ what, p.peek().text });
        return false;
    }
    pub fn text(p: *const Parser, tok: u32) []const u8 {
        return p.toks[tok].text;
    }

    fn node(p: *Parser, kind: N, ln: u32) u32 {
        if (p.n >= p.nodes.len) {
            if (!p.full) p.log.err(ln, "shader too long ({d} nodes at most)", .{p.nodes.len});
            p.full = true;
            return 0;
        }
        p.nodes[p.n] = .{ .kind = kind, .line = ln };
        p.n += 1;
        return p.n - 1;
    }

    fn set(p: *Parser, i: u32) *Node {
        // (node 0 is a sink when the nodes ran out)
        return &p.nodes[i];
    }

    /// Appends child `c` to `parent`'s list (a), `last` its last.
    fn link(p: *Parser, parent: u32, last: *u32, c: u32) void {
        if (c == 0) return;
        if (last.* == 0) p.set(parent).a = c else p.set(last.*).next = c;
        last.* = c;
    }

    // ── Types and qualifiers ───────────────────────────────────────────────

    fn isStructName(p: *const Parser, t: Token) bool {
        if (t.kind != .ident or t.kw != .none) return false;
        for (p.struct_names[0..p.nstructs]) |s| {
            if (std.mem.eql(u8, s, t.text)) return true;
        }
        return false;
    }

    fn isTypeKw(kw: Kw) bool {
        return @intFromEnum(kw) >= @intFromEnum(Kw.void) and @intFromEnum(kw) <= @intFromEnum(Kw.samplerExternalOES);
    }

    fn isQualKw(kw: Kw) bool {
        return switch (kw) {
            .@"const", .uniform, .layout, .centroid, .flat, .smooth, .in, .out, .inout, .attribute, .varying, .invariant, .lowp, .mediump, .highp => true,
            else => false,
        };
    }

    /// Whether a declaration starts here (a qualifier, a type, a struct).
    fn startsDecl(p: *const Parser) bool {
        const t = p.peek();
        if (t.kind != .ident) return false;
        if (isQualKw(t.kw) or isTypeKw(t.kw) or t.kw == .@"struct" or t.kw == .precision) {
            // (a constructor call is an expression: `vec4(...)`, `vec4[2](...)`)
            if (isTypeKw(t.kw) and (p.peekAt(1).kind == .lparen or (p.peekAt(1).kind == .lbracket and p.ctorArray()))) return false;
            return true;
        }
        if (p.isStructName(t)) {
            const n1 = p.peekAt(1);
            return n1.kind == .ident or (n1.kind == .lbracket and !p.ctorArray());
        }
        return false;
    }

    /// `T[...](`: an array constructor (not a declaration's array type).
    fn ctorArray(p: *const Parser) bool {
        var k: usize = 1;
        var depth: u32 = 0;
        while (p.at + k < p.toks.len) : (k += 1) {
            const t = p.peekAt(k);
            if (t.kind == .lbracket) depth += 1;
            if (t.kind == .rbracket) {
                depth -= 1;
                if (depth == 0) return p.peekAt(k + 1).kind == .lparen;
            }
            if (t.kind == .eof or t.kind == .semicolon) return false;
        }
        return false;
    }

    /// Qualifiers: their bits, the precision, a layout location (+1).
    fn qualifiers(p: *Parser) struct { flags: u16, location: u32, precision: Kw } {
        var flags: u16 = 0;
        var location: u32 = 0;
        var pq: Kw = .none;
        while (true) {
            const t = p.peek();
            if (t.kind != .ident) break;
            switch (t.kw) {
                .@"const" => flags |= Q.@"const",
                .uniform => flags |= Q.uniform,
                .in => flags |= Q.in,
                .out => flags |= Q.out,
                .inout => flags |= Q.inout,
                .centroid => flags |= Q.centroid,
                .flat => flags |= Q.flat,
                .smooth => flags |= Q.smooth,
                .invariant => flags |= Q.invariant,
                .attribute => flags |= Q.attribute | Q.in,
                .varying => flags |= Q.varying,
                .lowp, .mediump, .highp => {
                    pq = t.kw;
                    flags |= Q.precision;
                },
                .layout => {
                    _ = p.take();
                    if (!p.expect(.lparen, "`(` after layout")) return .{ .flags = flags, .location = location, .precision = pq };
                    while (!p.is(.rparen) and !p.is(.eof)) {
                        const id = p.peek();
                        _ = p.take();
                        if (p.accept(.assign)) {
                            const v = p.peek();
                            _ = p.take();
                            if (std.mem.eql(u8, id.text, "location")) {
                                if (v.kind == .int_lit or v.kind == .uint_lit) location = (lex.intValue(v.text) orelse 0) + 1 else p.log.err(v.line, "layout location needs a number", .{});
                            } else p.log.err(id.line, "layout qualifier `{s}` is not supported", .{id.text});
                        } else if (!std.mem.eql(u8, id.text, "std140") and !std.mem.eql(u8, id.text, "shared") and !std.mem.eql(u8, id.text, "packed") and !std.mem.eql(u8, id.text, "row_major") and !std.mem.eql(u8, id.text, "column_major")) {
                            p.log.err(id.line, "layout qualifier `{s}` is not supported", .{id.text});
                        }
                        if (!p.accept(.comma)) break;
                    }
                    _ = p.expect(.rparen, "`)`");
                    continue;
                },
                else => break,
            }
            _ = p.take();
        }
        return .{ .flags = flags, .location = location, .precision = pq };
    }

    /// `[ size ]` or `[]`: the size expression (0 for `[]`), unsized set.
    fn arraySuffix(p: *Parser, unsized: *bool) u32 {
        if (!p.accept(.lbracket)) return 0;
        if (p.accept(.rbracket)) {
            unsized.* = true;
            return 0;
        }
        const e = p.conditional();
        _ = p.expect(.rbracket, "`]`");
        return e;
    }

    /// A type: a keyword, a struct's name, or a struct defined here.
    fn typeSpec(p: *Parser) u32 {
        const ln = p.line();
        const ts = p.node(.type_spec, ln);
        const t = p.peek();
        if (t.kind == .ident and t.kw == .@"struct") {
            _ = p.take();
            const sd = p.node(.struct_def, ln);
            if (p.peek().kind == .ident and p.peek().kw == .none) {
                p.set(sd).tok = p.take();
                if (p.nstructs < MAX_STRUCT_NAMES) {
                    p.struct_names[p.nstructs] = p.text(p.set(sd).tok);
                    p.nstructs += 1;
                }
            }
            if (!p.expect(.lbrace, "`{` of a struct")) return ts;
            var last: u32 = 0;
            while (!p.is(.rbrace) and !p.is(.eof)) {
                const before = p.at;
                const q = p.qualifiers();
                if (q.flags & ~Q.precision != 0) p.log.err(p.line(), "struct members take no qualifiers", .{});
                const mt = p.typeSpec();
                // a member decl: a = type, b = first declarator
                const md = p.node(.decl, p.line());
                p.set(md).a = mt;
                var first: u32 = 0;
                var dlast: u32 = 0;
                while (true) {
                    if (p.peek().kind != .ident) {
                        p.log.err(p.line(), "expected a member name, found `{s}`", .{p.peek().text});
                        break;
                    }
                    const v = p.node(.@"var", p.line());
                    p.set(v).tok = p.take();
                    var unsized = false;
                    p.set(v).a = p.arraySuffix(&unsized);
                    if (unsized) p.log.err(p.line(), "struct members need a size", .{});
                    if (first == 0) first = v else p.set(dlast).next = v;
                    dlast = v;
                    if (!p.accept(.comma)) break;
                }
                p.set(md).b = first;
                _ = p.expect(.semicolon, "`;` after a member");
                p.link(sd, &last, md);
                if (p.at == before) p.at += 1;
            }
            _ = p.expect(.rbrace, "`}`");
            p.set(ts).a = sd;
            p.set(ts).tok = p.set(sd).tok;
        } else if (t.kind == .ident and (isTypeKw(t.kw) or p.isStructName(t))) {
            p.set(ts).tok = p.take();
        } else {
            p.log.err(ln, "expected a type, found `{s}`", .{t.text});
            if (!p.is(.eof)) _ = p.take();
            return ts;
        }
        var unsized = false;
        p.set(ts).b = p.arraySuffix(&unsized);
        if (unsized) p.set(ts).op = 1;
        return ts;
    }

    // ── Declarations ───────────────────────────────────────────────────────

    fn external(p: *Parser) u32 {
        if (p.accept(.semicolon)) return 0;
        return p.declaration(true);
    }

    /// A declaration, or (at the top) a function.
    fn declaration(p: *Parser, top: bool) u32 {
        const ln = p.line();
        if (p.isKw(.precision)) {
            _ = p.take();
            const pr = p.node(.precision, ln);
            const q = p.peek();
            if (q.kw != .lowp and q.kw != .mediump and q.kw != .highp) p.log.err(ln, "precision needs lowp, mediump or highp", .{});
            _ = p.take();
            p.set(pr).op = @intFromEnum(q.kw);
            const t = p.peek();
            if (t.kind != .ident or !isTypeKw(t.kw)) p.log.err(ln, "precision needs a type", .{});
            p.set(pr).tok = p.take();
            _ = p.expect(.semicolon, "`;`");
            return pr;
        }
        const q = p.qualifiers();
        // `invariant name;` (and 1.00's `invariant varying`'s re-declaration)
        if (q.flags == Q.invariant and p.peek().kind == .ident and p.peek().kw == .none and !p.isStructName(p.peek())) {
            const iv = p.node(.invariant, ln);
            p.set(iv).tok = p.take();
            while (p.accept(.comma)) _ = p.take();
            _ = p.expect(.semicolon, "`;`");
            return iv;
        }
        // an interface block: `uniform Name { ... } name;`
        if (q.flags & (Q.uniform | Q.in | Q.out) != 0 and p.peek().kind == .ident and p.peek().kw == .none and !p.isStructName(p.peek()) and p.peekAt(1).kind == .lbrace) {
            const bd = p.node(.block_decl, ln);
            p.set(bd).tok = p.take();
            var depth: u32 = 0;
            while (!p.is(.eof)) {
                const t = p.peek();
                _ = p.take();
                if (t.kind == .lbrace) depth += 1;
                if (t.kind == .rbrace) {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            while (!p.is(.semicolon) and !p.is(.eof)) _ = p.take();
            _ = p.accept(.semicolon);
            return bd;
        }
        const ts = p.typeSpec();
        p.set(ts).flags = q.flags;
        // a function: type name (
        if (top and p.peek().kind == .ident and p.peekAt(1).kind == .lparen) {
            return p.function(ts, q.flags);
        }
        const d = p.node(.decl, ln);
        p.set(d).a = ts;
        p.set(d).flags = q.flags;
        // `struct S { ... };` alone, or a type with no name
        if (p.accept(.semicolon)) return d;
        var last: u32 = 0;
        var first: u32 = 0;
        while (true) {
            const v = p.node(.@"var", p.line());
            if (p.peek().kind != .ident or p.peek().kw != .none) {
                p.log.err(p.line(), "expected a name, found `{s}`", .{p.peek().text});
                break;
            }
            p.set(v).tok = p.take();
            p.set(v).flags = q.flags;
            p.set(v).value = q.location;
            var unsized = false;
            p.set(v).a = p.arraySuffix(&unsized);
            if (unsized) p.set(v).op = 1;
            if (p.accept(.assign)) p.set(v).b = p.initializer();
            if (first == 0) first = v else p.set(last).next = v;
            last = v;
            if (!p.accept(.comma)) break;
        }
        p.set(d).b = first;
        _ = p.expect(.semicolon, "`;` after a declaration");
        return d;
    }

    fn initializer(p: *Parser) u32 {
        if (p.is(.lbrace)) {
            p.log.err(p.line(), "initializer lists `{{...}}` are not GLSL ES", .{});
            while (!p.is(.rbrace) and !p.is(.eof)) _ = p.take();
            _ = p.accept(.rbrace);
            return 0;
        }
        return p.assignment();
    }

    fn function(p: *Parser, ret: u32, flags: u16) u32 {
        const ln = p.line();
        const f = p.node(.func, ln);
        if (flags & ~Q.precision != 0) p.log.err(ln, "a function's return type takes no qualifiers", .{});
        p.set(f).tok = p.take();
        p.set(f).a = ret;
        _ = p.take(); // (
        var last: u32 = 0;
        var first: u32 = 0;
        // `(void)`: none
        if (p.isKw(.void) and p.peekAt(1).kind == .rparen) _ = p.take();
        while (!p.is(.rparen) and !p.is(.eof)) {
            const pl = p.line();
            const q = p.qualifiers();
            const pt = p.typeSpec();
            const pm = p.node(.param, pl);
            p.set(pm).a = pt;
            p.set(pm).flags = q.flags;
            if (p.peek().kind == .ident and p.peek().kw == .none) {
                p.set(pm).tok = p.take();
                var unsized = false;
                p.set(pm).b = p.arraySuffix(&unsized);
            }
            if (first == 0) first = pm else p.set(last).next = pm;
            last = pm;
            if (!p.accept(.comma)) break;
        }
        _ = p.expect(.rparen, "`)` after parameters");
        p.set(f).b = first;
        if (p.accept(.semicolon)) return f;
        p.set(f).c = p.block();
        return f;
    }

    // ── Statements ─────────────────────────────────────────────────────────

    fn block(p: *Parser) u32 {
        const ln = p.line();
        const b = p.node(.block, ln);
        if (!p.expect(.lbrace, "`{`")) return b;
        var last: u32 = 0;
        while (!p.is(.rbrace) and !p.is(.eof) and p.log.errors < 20) {
            const before = p.at;
            p.link(b, &last, p.statement());
            if (p.at == before) _ = p.take();
        }
        _ = p.expect(.rbrace, "`}`");
        return b;
    }

    fn statement(p: *Parser) u32 {
        const ln = p.line();
        const t = p.peek();
        if (t.kind == .lbrace) return p.block();
        if (t.kind == .semicolon) {
            _ = p.take();
            return p.node(.empty, ln);
        }
        if (t.kind == .ident) switch (t.kw) {
            .@"if" => {
                _ = p.take();
                const s = p.node(.@"if", ln);
                _ = p.expect(.lparen, "`(`");
                p.set(s).a = p.expression();
                _ = p.expect(.rparen, "`)`");
                p.set(s).b = p.statement();
                if (p.isKw(.@"else")) {
                    _ = p.take();
                    p.set(s).c = p.statement();
                }
                return s;
            },
            .@"for" => {
                _ = p.take();
                const s = p.node(.@"for", ln);
                _ = p.expect(.lparen, "`(`");
                p.set(s).a = if (p.startsDecl()) p.declStmt() else p.exprStmt();
                if (!p.is(.semicolon)) p.set(s).b = p.expression();
                _ = p.expect(.semicolon, "`;`");
                if (!p.is(.rparen)) p.set(s).c = p.expression();
                _ = p.expect(.rparen, "`)`");
                p.set(s).d = p.statement();
                return s;
            },
            .@"while" => {
                _ = p.take();
                const s = p.node(.@"while", ln);
                _ = p.expect(.lparen, "`(`");
                p.set(s).a = p.expression();
                _ = p.expect(.rparen, "`)`");
                p.set(s).b = p.statement();
                return s;
            },
            .do => {
                _ = p.take();
                const s = p.node(.do, ln);
                p.set(s).a = p.statement();
                if (!p.isKw(.@"while")) p.log.err(p.line(), "expected `while` after `do`", .{}) else _ = p.take();
                _ = p.expect(.lparen, "`(`");
                p.set(s).b = p.expression();
                _ = p.expect(.rparen, "`)`");
                _ = p.expect(.semicolon, "`;`");
                return s;
            },
            .@"switch" => {
                _ = p.take();
                const s = p.node(.@"switch", ln);
                _ = p.expect(.lparen, "`(`");
                p.set(s).a = p.expression();
                _ = p.expect(.rparen, "`)`");
                p.set(s).b = p.block();
                return s;
            },
            .case => {
                _ = p.take();
                const s = p.node(.case, ln);
                p.set(s).a = p.expression();
                _ = p.expect(.colon, "`:`");
                return s;
            },
            .default => {
                _ = p.take();
                const s = p.node(.default, ln);
                _ = p.expect(.colon, "`:`");
                return s;
            },
            .@"break", .@"continue", .discard => {
                _ = p.take();
                const s = p.node(switch (t.kw) {
                    .@"break" => .@"break",
                    .@"continue" => .@"continue",
                    else => .discard,
                }, ln);
                _ = p.expect(.semicolon, "`;`");
                return s;
            },
            .@"return" => {
                _ = p.take();
                const s = p.node(.@"return", ln);
                if (!p.is(.semicolon)) p.set(s).a = p.expression();
                _ = p.expect(.semicolon, "`;`");
                return s;
            },
            else => {},
        };
        if (p.startsDecl()) return p.declStmt();
        return p.exprStmt();
    }

    fn declStmt(p: *Parser) u32 {
        const s = p.node(.decl_stmt, p.line());
        p.set(s).a = p.declaration(false);
        return s;
    }

    fn exprStmt(p: *Parser) u32 {
        const s = p.node(.expr_stmt, p.line());
        if (!p.is(.semicolon)) p.set(s).a = p.expression();
        _ = p.expect(.semicolon, "`;`");
        return s;
    }

    // ── Expressions ────────────────────────────────────────────────────────

    pub fn expression(p: *Parser) u32 {
        var e = p.assignment();
        while (p.is(.comma)) {
            const ln = p.line();
            _ = p.take();
            const s = p.node(.sequence, ln);
            p.set(s).a = e;
            p.set(s).b = p.assignment();
            e = s;
        }
        return e;
    }

    fn assignment(p: *Parser) u32 {
        const l = p.conditional();
        const k = p.peek().kind;
        switch (k) {
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign, .shl_assign, .shr_assign, .and_assign, .xor_assign, .or_assign => {
                const ln = p.line();
                _ = p.take();
                const a = p.node(.assign, ln);
                p.set(a).op = @intFromEnum(k);
                p.set(a).a = l;
                p.set(a).b = p.assignment();
                return a;
            },
            else => return l,
        }
    }

    fn conditional(p: *Parser) u32 {
        const c = p.binary(0);
        if (!p.is(.question)) return c;
        const ln = p.line();
        _ = p.take();
        const t = p.node(.ternary, ln);
        p.set(t).a = c;
        p.set(t).b = p.expression();
        _ = p.expect(.colon, "`:` of `?:`");
        p.set(t).c = p.assignment();
        return t;
    }

    fn prec(k: Kind) u8 {
        return switch (k) {
            .or_or => 1,
            .xor_xor => 2,
            .and_and => 3,
            .pipe => 4,
            .caret => 5,
            .amp => 6,
            .eq, .ne => 7,
            .lt, .gt, .le, .ge => 8,
            .shl, .shr => 9,
            .plus, .minus => 10,
            .star, .slash, .percent => 11,
            else => 0,
        };
    }

    fn binary(p: *Parser, min: u8) u32 {
        var l = p.unary();
        while (true) {
            const k = p.peek().kind;
            const pr = prec(k);
            if (pr == 0 or pr <= min) break;
            const ln = p.line();
            _ = p.take();
            const b = p.node(.binary, ln);
            p.set(b).op = @intFromEnum(k);
            p.set(b).a = l;
            p.set(b).b = p.binary(pr);
            l = b;
        }
        return l;
    }

    fn unary(p: *Parser) u32 {
        const ln = p.line();
        const k = p.peek().kind;
        switch (k) {
            .plus, .minus, .bang, .tilde => {
                _ = p.take();
                const u = p.node(.unary, ln);
                p.set(u).op = @intFromEnum(k);
                p.set(u).a = p.unary();
                return u;
            },
            .inc, .dec => {
                _ = p.take();
                const u = p.node(if (k == .inc) .pre_inc else .pre_dec, ln);
                p.set(u).a = p.unary();
                return u;
            },
            else => return p.postfix(p.primary()),
        }
    }

    fn postfix(p: *Parser, base: u32) u32 {
        var e = base;
        while (true) {
            const ln = p.line();
            switch (p.peek().kind) {
                .lbracket => {
                    _ = p.take();
                    const x = p.node(.index, ln);
                    p.set(x).a = e;
                    p.set(x).b = p.expression();
                    _ = p.expect(.rbracket, "`]`");
                    e = x;
                },
                .dot => {
                    _ = p.take();
                    const x = p.node(.field, ln);
                    p.set(x).a = e;
                    if (p.peek().kind != .ident) {
                        p.log.err(ln, "expected a field after `.`", .{});
                        return e;
                    }
                    p.set(x).tok = p.take();
                    // `x.length()`: an array's length
                    if (p.is(.lparen) and std.mem.eql(u8, p.text(p.set(x).tok), "length")) {
                        _ = p.take();
                        _ = p.expect(.rparen, "`)` of length()");
                        p.set(x).op = 1;
                    }
                    e = x;
                },
                .inc, .dec => {
                    const x = p.node(if (p.peek().kind == .inc) .post_inc else .post_dec, ln);
                    _ = p.take();
                    p.set(x).a = e;
                    e = x;
                },
                else => return e,
            }
        }
    }

    fn args(p: *Parser, call: u32) void {
        _ = p.take(); // (
        var last: u32 = 0;
        var first: u32 = 0;
        if (p.isKw(.void) and p.peekAt(1).kind == .rparen) _ = p.take();
        while (!p.is(.rparen) and !p.is(.eof)) {
            const a = p.assignment();
            if (a == 0) break;
            if (first == 0) first = a else p.set(last).next = a;
            last = a;
            if (!p.accept(.comma)) break;
        }
        _ = p.expect(.rparen, "`)` after arguments");
        p.set(call).b = first;
    }

    fn primary(p: *Parser) u32 {
        const ln = p.line();
        const t = p.peek();
        switch (t.kind) {
            .int_lit, .uint_lit => {
                const e = p.node(if (t.kind == .int_lit) .int_lit else .uint_lit, ln);
                p.set(e).tok = p.take();
                if (lex.intValue(t.text)) |v| p.set(e).value = v else p.log.err(ln, "integer literal too large: {s}", .{t.text});
                return e;
            },
            .float_lit => {
                const e = p.node(.float_lit, ln);
                p.set(e).tok = p.take();
                p.set(e).value = @bitCast(lex.floatValue(t.text));
                return e;
            },
            .lparen => {
                _ = p.take();
                const e = p.expression();
                _ = p.expect(.rparen, "`)`");
                return e;
            },
            .ident => {
                if (t.kw == .true or t.kw == .false) {
                    const e = p.node(.bool_lit, ln);
                    p.set(e).tok = p.take();
                    p.set(e).value = @intFromBool(t.kw == .true);
                    return e;
                }
                // a constructor: a type (perhaps an array type) and `(`
                if (isTypeKw(t.kw) or p.isStructName(t)) {
                    const c = p.node(.call, ln);
                    const ts = p.node(.type_spec, ln);
                    p.set(ts).tok = p.take();
                    var unsized = false;
                    p.set(ts).b = p.arraySuffix(&unsized);
                    if (unsized) p.set(ts).op = 1;
                    p.set(c).a = ts;
                    if (!p.is(.lparen)) {
                        p.log.err(ln, "expected `(` after the type `{s}`", .{t.text});
                        return c;
                    }
                    p.args(c);
                    return c;
                }
                if (t.kw != .none) {
                    p.log.err(ln, "unexpected `{s}`", .{t.text});
                    _ = p.take();
                    return p.node(.empty, ln);
                }
                if (p.peekAt(1).kind == .lparen) {
                    const c = p.node(.call, ln);
                    p.set(c).tok = p.take();
                    p.args(c);
                    return c;
                }
                const e = p.node(.ident, ln);
                p.set(e).tok = p.take();
                return e;
            },
            else => {
                p.log.err(ln, "expected an expression, found `{s}`", .{if (t.kind == .eof) "the end" else t.text});
                if (t.kind != .eof and t.kind != .semicolon and t.kind != .rbrace) _ = p.take();
                return p.node(.empty, ln);
            },
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

var t_out: [2048]Token = undefined;
var t_work: [2048]Token = undefined;
var t_clean: [8192]u8 = undefined;
var t_logbuf: [4096]u8 = undefined;
var t_pp: pp.Pp = undefined;
var t_log: pp.Log = undefined;
var t_nodes: [4096]Node = undefined;

pub fn testParse(src: []const u8) struct { p: Parser, root: u32, ext: pp.Extensions } {
    t_log = .{ .buf = &t_logbuf };
    t_pp = .{ .log = &t_log, .out = &t_out, .work = &t_work };
    t_pp.run(src, &t_clean);
    var p = Parser{ .toks = t_out[0..t_pp.n], .nodes = &t_nodes, .log = &t_log, .version = t_pp.version };
    const root = p.run();
    return .{ .p = p, .root = root, .ext = t_pp.ext };
}

fn count(p: *const Parser, first: u32, kind: N) usize {
    var n: usize = 0;
    var i = first;
    while (i != 0) : (i = p.nodes[i].next) {
        if (p.nodes[i].kind == kind) n += 1;
    }
    return n;
}

test "parse: declarations, a struct, functions, statements" {
    const src =
        \\#version 300 es
        \\precision highp float;
        \\struct Rect { vec2 p0; vec2 size; };
        \\layout(location = 1) in vec2 aPos;
        \\flat out ivec4 vData[2];
        \\uniform mat4 uTransform;
        \\const int N = 4;
        \\Rect make(vec2 p, vec2 s) { return Rect(p, s); }
        \\float f(in float x, out float y);
        \\void main() {
        \\    Rect r = make(aPos, vec2(1.0));
        \\    vec4 c[2] = vec4[2](vec4(0.0), vec4(1.0));
        \\    for (int i = 0; i < N; i++) { if (i == 2) continue; else r.p0.xy += vec2(float(i)); }
        \\    int k = (1 + 2) * 3 << 1 | 4 & 7;
        \\    gl_Position = uTransform * vec4(r.p0, 0.0, 1.0) + c[1].wzyx;
        \\    switch (k) { case 1: break; default: k = k > 0 ? 1 : 2; }
        \\    do { k--; } while (k > 0);
        \\}
    ;
    const r = testParse(src);
    if (t_log.errors != 0) std.debug.print("{s}", .{t_log.text()});
    try std.testing.expectEqual(@as(u32, 0), t_log.errors);
    const p = &r.p;
    const first = p.nodes[r.root].a;
    try std.testing.expectEqual(@as(usize, 1), count(p, first, .precision));
    try std.testing.expectEqual(@as(usize, 3), count(p, first, .func));
    try std.testing.expectEqual(@as(usize, 5), count(p, first, .decl));
    // the location of aPos: 1 (+1)
    var i = first;
    while (i != 0) : (i = p.nodes[i].next) {
        const nd = p.nodes[i];
        if (nd.kind == .decl and nd.b != 0 and std.mem.eql(u8, p.text(p.nodes[nd.b].tok), "aPos")) {
            try std.testing.expectEqual(@as(u32, 2), p.nodes[nd.b].value);
            try std.testing.expect(p.nodes[nd.b].flags & Q.in != 0);
        }
        if (nd.kind == .decl and nd.b != 0 and std.mem.eql(u8, p.text(p.nodes[nd.b].tok), "vData")) {
            try std.testing.expect(p.nodes[nd.b].flags & (Q.flat | Q.out) == Q.flat | Q.out);
            try std.testing.expect(p.nodes[nd.b].a != 0);
        }
    }
}

test "parse: what it says is wrong, by line" {
    _ = testParse("#version 300 es\nvoid main() {\n  float x = ;\n  int y = 1\n}\n");
    const log = t_log.text();
    try std.testing.expect(std.mem.indexOf(u8, log, "0:3: error: expected an expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "0:5: error: expected `;` after a declaration") != null);
}
