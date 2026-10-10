// @zpm/youtube/botguard/jsvm/parser — JavaScript Parser
//
// Recursive descent parser with Pratt precedence for expressions.
// Produces a flat AST node pool (fixed-size, no heap allocation).
// Covers the ES2020 subset required by BotGuard:
//   - All declarations (var/let/const, function, class)
//   - All control flow (if, for, while, do, switch, try/catch/finally)
//   - All expression forms (binary, unary, ternary, call, member, arrow, new)
//   - Object/array literals, property access, computed access
//   - Assignment (all compound forms)
//   - Spread, rest, destructuring patterns (basic)

const lexer = @import("lexer.sig");
const values = @import("values.sig");
const Token = lexer.Token;
const TokenType = lexer.TokenType;

// ── AST Node Types ──

pub const NodeType = enum(u8) {
    // Statements
    program, // top-level: children are statements
    block, // { ... }
    var_decl, // var/let/const x = expr
    func_decl, // function name(...) { body }
    class_decl, // class Name [extends Base] { ... }
    if_stmt, // if (cond) cons [else alt]
    for_stmt, // for (init; cond; update) body
    for_in_stmt, // for (x in obj) body
    for_of_stmt, // for (x of iter) body
    while_stmt, // while (cond) body
    do_while_stmt, // do body while (cond)
    switch_stmt, // switch (disc) { cases }
    case_clause, // case expr: stmts | default: stmts
    try_stmt, // try { } catch (e) { } finally { }
    return_stmt, // return [expr]
    throw_stmt, // throw expr
    break_stmt, // break [label]
    continue_stmt, // continue [label]
    expr_stmt, // expression ;
    empty_stmt, // ;
    with_stmt, // with (obj) body
    label_stmt, // label: stmt
    debugger_stmt, // debugger

    // Expressions
    literal_num, // number literal
    literal_str, // string literal
    literal_bool, // true/false
    literal_null, // null
    literal_undef, // undefined
    literal_regex, // /pattern/flags
    literal_template, // `template`
    identifier, // variable reference
    this_expr, // this
    array_expr, // [a, b, c]
    object_expr, // { k: v, ... }
    property, // key: value (inside object)
    func_expr, // function(...) { }
    arrow_expr, // (...) => { } | (...) => expr
    class_expr, // class [Name] { ... }
    unary_expr, // prefix: ! - ~ typeof void delete ++ --
    postfix_expr, // postfix: ++ --
    binary_expr, // a op b
    logical_expr, // a && b, a || b, a ?? b
    assign_expr, // a = b, a += b, etc.
    cond_expr, // a ? b : c
    call_expr, // f(args)
    new_expr, // new F(args)
    member_expr, // a.b
    computed_expr, // a[b]
    optional_expr, // a?.b, a?.[b], a?.()
    sequence_expr, // a, b, c
    spread_expr, // ...expr
    yield_expr, // yield [expr]
    await_expr, // await expr
    typeof_expr, // typeof expr
    void_expr, // void expr
    delete_expr, // delete expr
};

/// An AST node (20 bytes). Children referenced by index into the node pool.
pub const Node = struct {
    tag: NodeType, // 1 byte
    flags: NodeFlags, // 1 byte
    op: u8 = 0, // operator token type (for binary/unary/assign)
    _pad: u8 = 0,
    token_idx: u32 = 0, // index of primary token (u32: BotGuard's 63KB payload
    // produces >65535 tokens, so a u16 token index truncated/panicked).
    left: NodeIdx = NULL_NODE, // left child / condition / first param
    right: NodeIdx = NULL_NODE, // right child / consequent
    extra: NodeIdx = NULL_NODE, // alternate / third child / extra info
    end_pos: u32 = 0, // source byte offset just past this node (for function toString)
};

pub const NodeFlags = packed struct(u8) {
    is_const: bool = false, // const declaration
    is_let: bool = false, // let declaration (else var)
    is_async: bool = false, // async function/arrow
    is_generator: bool = false, // function* / yield*
    is_computed: bool = false, // computed property key
    is_getter: bool = false, // get accessor
    is_setter: bool = false, // set accessor
    is_static: bool = false, // static class member
};

// u32: BotGuard's minified interpreter (~63KB) parses to well over 65535 AST
// nodes and list items; a u16 NodeIdx overflowed the node/list pools, silently
// truncating list-start offsets so late `var` declarators (e.g. the module-scope
// function `w`) were dropped -> `w is not defined` at runtime.
pub const NodeIdx = u32;
pub const NULL_NODE: NodeIdx = 0xFFFFFFFF;

/// Maximum AST nodes (~256KB with 20-byte nodes = ~13000 nodes).
pub const MAX_NODES: usize = 400000;

/// List pool — for variable-length child lists (params, args, stmts, etc.)
/// Each list entry is a NodeIdx. Lists are contiguous ranges in this pool.
pub const MAX_LIST_ITEMS: usize = 400000;

// ── Parser State ──

var nodes: [MAX_NODES]Node = undefined;
var n_nodes: u32 = 0;

/// List pool: flat array of NodeIdx values.
/// Lists are referenced by (start, len) stored in a node's left/right fields.
var list_pool: [MAX_LIST_ITEMS]NodeIdx = undefined;
var list_used: u32 = 0;

var tok_pos: usize = 0; // current token index
var tok_count: usize = 0; // total tokens from lexer
var had_error: bool = false;

// When true, `in` is NOT treated as a relational operator. Used while parsing
// a for-loop initializer so `for (x in obj)` detects the for-in form instead
// of parsing `x in obj` as a binary expression (the ES "NoIn" grammar).
var no_in: bool = false;

// ── Public API ──

/// Parse the token stream (after lexer.tokenize has been called).
/// Returns the root node index (a .program node), or NULL_NODE on failure.
pub fn parse(num_tokens: usize) NodeIdx {
    tok_count = num_tokens;
    tok_pos = 0;
    n_nodes = 0;
    list_used = 0;
    had_error = false;

    // Allocate root program node
    const root = allocNode(.program);
    if (root == NULL_NODE) return NULL_NODE;

    // Parse top-level statements. Gather direct children into a local buffer
    // first, then commit contiguously — nested parsing pushes into the shared
    // pool, so we must not use a raw list_used span here.
    var stmts: [MAX_TOP_STMTS]NodeIdx = undefined;
    var n: usize = 0;
    while (!atEnd() and !had_error) {
        const stmt = parseStatement();
        if (stmt != NULL_NODE and n < MAX_TOP_STMTS) {
            stmts[n] = stmt;
            n += 1;
        }
    }
    const list_start = commitList(stmts[0..n]);

    nodes[root].left = list_start;
    nodes[root].right = @intCast(n);
    return root;
}

/// Maximum statements at a single block/program level.
pub const MAX_TOP_STMTS: usize = 4096;

/// Get a parsed node.
pub fn getNode(idx: NodeIdx) Node {
    if (idx == NULL_NODE or idx >= n_nodes) return .{ .tag = .empty_stmt, .flags = .{} };
    return nodes[idx];
}

/// Get a slice of the list pool.
pub fn getList(start: u32, len: u32) []const NodeIdx {
    if (start + len > list_used) return &[_]NodeIdx{};
    return list_pool[start .. start + len];
}

/// Get total node count.
pub fn nodeCount() u32 {
    return n_nodes;
}

/// Whether a parse error occurred.
pub fn hasError() bool {
    return had_error;
}

/// True if a parse error occurred AND the parser ran off the end of the token
/// stream (current token is EOF) — i.e. the input was INCOMPLETE. JS engines
/// report this as SyntaxError "Unexpected end of input". BotGuard's anti-tamper
/// deliberately `eval`s truncated source to force exactly this error, so our
/// eval must throw it (not silently return undefined) for the transcript to
/// match the reference. A non-EOF syntax error is a different message.
pub fn errorWasUnexpectedEof() bool {
    return had_error and peek().tt == .eof;
}

/// Current token position (how far parsing advanced). For diagnostics.
pub fn tokenPos() usize {
    return tok_pos;
}

/// Total token count the parser was given. For diagnostics.
pub fn tokenCount() usize {
    return tok_count;
}

/// Token type (enum int) at the current position. For diagnostics.
pub fn currentTokenType() u8 {
    return @intFromEnum(peek().tt);
}

/// Byte offset in source of the current token. For diagnostics.
pub fn currentTokenStart() u32 {
    return peek().start;
}

// ── Statement Parsing ──

fn parseStatement() NodeIdx {
    const tok = peek();
    return switch (tok.tt) {
        .semicolon => parseEmptyStmt(),
        .lbrace => parseBlock(),
        .kw_var, .kw_let, .kw_const => parseVarDecl(),
        .kw_function => parseFuncDecl(),
        .kw_class => parseClassDecl(),
        .kw_if => parseIfStmt(),
        .kw_for => parseForStmt(),
        .kw_while => parseWhileStmt(),
        .kw_do => parseDoWhileStmt(),
        .kw_switch => parseSwitchStmt(),
        .kw_try => parseTryStmt(),
        .kw_return => parseReturnStmt(),
        .kw_throw => parseThrowStmt(),
        .kw_break => parseBreakStmt(),
        .kw_continue => parseContinueStmt(),
        .kw_with => parseWithStmt(),
        .kw_debugger => parseDebuggerStmt(),
        .kw_async => parseAsyncPrefix(),
        .eof => NULL_NODE,
        else => parseLabelOrExprStmt(),
    };
}

fn parseEmptyStmt() NodeIdx {
    advance(); // consume ;
    return allocNode(.empty_stmt);
}

fn parseBlock() NodeIdx {
    advance(); // consume {
    const node = allocNode(.block);
    if (node == NULL_NODE) return NULL_NODE;

    var stmts: [MAX_TOP_STMTS]NodeIdx = undefined;
    var n: usize = 0;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        const stmt = parseStatement();
        if (stmt != NULL_NODE and n < MAX_TOP_STMTS) {
            stmts[n] = stmt;
            n += 1;
        }
    }
    expect(.rbrace);
    const list_start = commitList(stmts[0..n]);

    nodes[node].left = list_start;
    nodes[node].right = @intCast(n);
    return node;
}

fn parseVarDecl() NodeIdx {
    const tok = peek();
    const flags = NodeFlags{
        .is_const = tok.tt == .kw_const,
        .is_let = tok.tt == .kw_let,
    };
    advance(); // consume var/let/const

    const node = allocNode(.var_decl);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].flags = flags;

    // Parse declarators as [name, init] pairs into a local buffer, then commit.
    // BotGuard's minified payload emits a SINGLE `var` statement with hundreds
    // of declarators (its whole function table), so this buffer must be large;
    // a small cap here would silently drop later declarators (name+init never
    // stored) while still consuming their tokens — losing those globals.
    const MAX_DECLARATORS: usize = 4096; // name+init pairs (BotGuard's interpreter
    // IIFE declares its entire function table in ONE `var` — hundreds of them).
    var items: [MAX_DECLARATORS * 2]NodeIdx = undefined;
    var count: u16 = 0;
    while (true) {
        // Name (or destructuring pattern — for now just identifiers)
        const name = parseBindingPattern();
        if (count < items.len) { items[count] = name; count += 1; } else had_error = true;

        // Optional initializer
        if (check(.assign)) {
            advance(); // consume =
            const init = parseAssignment();
            if (count < items.len) { items[count] = init; count += 1; } else had_error = true;
        } else {
            if (count < items.len) { items[count] = NULL_NODE; count += 1; } else had_error = true;
        }

        if (!check(.comma)) break;
        advance(); // consume ,
    }
    consumeSemicolon();

    nodes[node].left = commitList(items[0..count]);
    nodes[node].right = @intCast(count);
    if (count > dbg_max_var_items) dbg_max_var_items = count;
    return node;
}
pub var dbg_max_var_items: u16 = 0;

fn parseBindingPattern() NodeIdx {
    // For now: just identifier. TODO: destructuring [...] and {...}
    if (check(.identifier)) {
        const node = allocNode(.identifier);
        if (node != NULL_NODE) {
            nodes[node].token_idx = @intCast(tok_pos);
        }
        advance();
        return node;
    }
    if (check(.lbracket)) return parseArrayExpr(); // array destructuring as array expr
    if (check(.lbrace)) return parseObjectExpr(); // object destructuring as object expr
    // Error
    had_error = true;
    return NULL_NODE;
}

fn parseFuncDecl() NodeIdx {
    return parseFunctionFull(false, false);
}

fn parseFunctionFull(is_async: bool, is_expr: bool) NodeIdx {
    const fn_tok = tok_pos; // token index of the `function` keyword (source pos)
    advance(); // consume 'function'
    const is_gen = check(.star);
    if (is_gen) advance(); // consume *

    const node = allocNode(if (is_expr) .func_expr else .func_decl);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].token_idx = @intCast(fn_tok);
    nodes[node].flags = .{ .is_async = is_async, .is_generator = is_gen };

    // Optional name
    if (check(.identifier)) {
        const name = allocNode(.identifier);
        if (name != NULL_NODE) nodes[name].token_idx = @intCast(tok_pos);
        advance();
        nodes[node].left = name;
    }

    // Parameters — gather into a local buffer, then commit before body.
    expect(.lparen);
    var params: [64]NodeIdx = undefined;
    var param_count: u16 = 0;
    while (!check(.rparen) and !atEnd() and !had_error) {
        var item: NodeIdx = NULL_NODE;
        if (check(.spread)) {
            advance();
            const rest = allocNode(.spread_expr);
            if (rest != NULL_NODE) {
                nodes[rest].left = parseBindingPattern();
            }
            item = rest;
        } else {
            const param = parseBindingPattern();
            // Optional default value
            if (check(.assign)) {
                advance();
                const def = parseAssignment();
                // Wrap in an assign node to store default
                const pair = allocNode(.assign_expr);
                if (pair != NULL_NODE) {
                    nodes[pair].left = param;
                    nodes[pair].right = def;
                }
                item = pair;
            } else {
                item = param;
            }
        }
        if (param_count < 64) { params[param_count] = item; param_count += 1; }
        if (!check(.rparen)) expect(.comma);
    }
    expect(.rparen);
    nodes[node].extra = commitList(params[0..param_count]);
    nodes[node].op = @intCast(param_count);

    // Body (must be a block)
    nodes[node].right = parseBlock();
    // Record the function's source END (just past the closing `}`) so the VM can
    // reconstruct the exact source for Function.prototype.toString. tok_pos now
    // points at the token AFTER the block; the `}` is the previous token.
    if (tok_pos >= 1) { const et = lexer.getToken(tok_pos - 1); nodes[node].end_pos = et.start + et.len; }
    return node;
}

fn parseClassDecl() NodeIdx {
    return parseClassFull(false);
}

fn parseClassFull(is_expr: bool) NodeIdx {
    advance(); // consume 'class'
    const node = allocNode(if (is_expr) .class_expr else .class_decl);
    if (node == NULL_NODE) return NULL_NODE;

    // Optional name
    if (check(.identifier)) {
        const name = allocNode(.identifier);
        if (name != NULL_NODE) nodes[name].token_idx = @intCast(tok_pos);
        advance();
        nodes[node].left = name;
    }

    // extends
    if (check(.kw_extends)) {
        advance();
        nodes[node].extra = parseLeftHandSide();
    }

    // Body { ... } — gather members locally, then commit.
    expect(.lbrace);
    var members: [256]NodeIdx = undefined;
    var count: u16 = 0;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        if (check(.semicolon)) { advance(); continue; }
        const member = parseClassMember();
        if (member != NULL_NODE and count < 256) { members[count] = member; count += 1; }
    }
    expect(.rbrace);
    nodes[node].right = commitList(members[0..count]);
    nodes[node].op = @intCast(@min(count, 255));
    return node;
}

fn parseClassMember() NodeIdx {
    var flags = NodeFlags{};
    if (checkIdentText("static")) { flags.is_static = true; advance(); }
    if (checkIdentText("get")) {
        // Could be getter or method named "get"
        if (!check(.lparen)) { flags.is_getter = true; advance(); }
    } else if (checkIdentText("set")) {
        if (!check(.lparen)) { flags.is_setter = true; advance(); }
    }

    // Method name (identifier, string, number, or [computed])
    var is_computed = false;
    const key: NodeIdx = blk: {
        if (check(.lbracket)) {
            is_computed = true;
            advance();
            const k = parseAssignment();
            expect(.rbracket);
            break :blk k;
        }
        if (check(.identifier) or check(.string) or check(.number)) {
            const k = allocNode(if (check(.identifier)) .identifier else if (check(.string)) .literal_str else .literal_num);
            if (k != NULL_NODE) nodes[k].token_idx = @intCast(tok_pos);
            advance();
            break :blk k;
        }
        had_error = true;
        break :blk NULL_NODE;
    };
    flags.is_computed = is_computed;

    // Value: method (has parens) or field (= expr ;)
    const prop_node = allocNode(.property);
    if (prop_node == NULL_NODE) return NULL_NODE;
    nodes[prop_node].flags = flags;
    nodes[prop_node].left = key;

    if (check(.lparen)) {
        // Method
        const method = parseMethodBody(false, false);
        nodes[prop_node].right = method;
    } else if (check(.assign)) {
        // Field with initializer
        advance();
        nodes[prop_node].right = parseAssignment();
        consumeSemicolon();
    } else {
        consumeSemicolon();
    }
    return prop_node;
}

fn parseMethodBody(is_async: bool, is_gen: bool) NodeIdx {
    const node = allocNode(.func_expr);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].token_idx = @intCast(tok_pos); // at `(` of method params (approx)
    nodes[node].flags = .{ .is_async = is_async, .is_generator = is_gen };

    expect(.lparen);
    var params: [64]NodeIdx = undefined;
    var param_count: u16 = 0;
    while (!check(.rparen) and !atEnd() and !had_error) {
        var item: NodeIdx = NULL_NODE;
        if (check(.spread)) {
            advance();
            const rest = allocNode(.spread_expr);
            if (rest != NULL_NODE) nodes[rest].left = parseBindingPattern();
            item = rest;
        } else {
            const param = parseBindingPattern();
            if (check(.assign)) {
                advance();
                const def = parseAssignment();
                const pair = allocNode(.assign_expr);
                if (pair != NULL_NODE) { nodes[pair].left = param; nodes[pair].right = def; }
                item = pair;
            } else {
                item = param;
            }
        }
        if (param_count < 64) { params[param_count] = item; param_count += 1; }
        if (!check(.rparen)) expect(.comma);
    }
    expect(.rparen);
    nodes[node].extra = commitList(params[0..param_count]);
    nodes[node].op = @intCast(param_count);
    nodes[node].right = parseBlock();
    return node;
}

fn parseIfStmt() NodeIdx {
    advance(); // consume 'if'
    expect(.lparen);
    const cond = parseExpression();
    expect(.rparen);
    const cons = parseStatement();
    var alt: NodeIdx = NULL_NODE;
    if (check(.kw_else)) {
        advance();
        alt = parseStatement();
    }
    const node = allocNode(.if_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = cond;
    nodes[node].right = cons;
    nodes[node].extra = alt;
    return node;
}

fn parseForStmt() NodeIdx {
    advance(); // consume 'for'
    expect(.lparen);

    // Could be: for(init;cond;update), for(x in obj), for(x of iter).
    // Parse the initializer in NoIn mode so `x in obj` is not eaten as a binary
    // `in` expression — we need to see the `in` to detect the for-in form.
    var init: NodeIdx = NULL_NODE;
    const saved_no_in = no_in;
    no_in = true;
    if (check(.semicolon)) {
        no_in = saved_no_in;
        advance(); // empty init
    } else if (check(.kw_var) or check(.kw_let) or check(.kw_const)) {
        // var decl without semicolon — check for in/of after first declarator
        init = parseForVarDecl();
        no_in = saved_no_in;
        if (init != NULL_NODE and (check(.kw_in) or checkOf())) {
            return parseForInOf(init);
        }
        expect(.semicolon);
    } else {
        init = parseExpression();
        no_in = saved_no_in;
        if (check(.kw_in) or checkOf()) {
            return parseForInOf(init);
        }
        expect(.semicolon);
    }

    // Standard for loop
    var cond: NodeIdx = NULL_NODE;
    if (!check(.semicolon)) cond = parseExpression();
    expect(.semicolon);

    var update: NodeIdx = NULL_NODE;
    if (!check(.rparen)) update = parseExpression();
    expect(.rparen);

    const body = parseStatement();

    const node = allocNode(.for_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = init;
    nodes[node].right = body;
    // Store cond and update in extra as a 2-item list.
    var cu: [2]NodeIdx = .{ cond, update };
    nodes[node].extra = commitList(cu[0..2]);
    return node;
}

fn parseForVarDecl() NodeIdx {
    const tok = peek();
    const flags = NodeFlags{
        .is_const = tok.tt == .kw_const,
        .is_let = tok.tt == .kw_let,
    };
    advance(); // consume var/let/const

    const node = allocNode(.var_decl);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].flags = flags;

    const name = parseBindingPattern();
    var init: NodeIdx = NULL_NODE;
    if (check(.assign)) {
        advance();
        init = parseAssignment();
    }
    var pair: [2]NodeIdx = .{ name, init };
    nodes[node].left = commitList(pair[0..2]);
    nodes[node].right = 2; // one declarator = 2 list items
    return node;
}

fn parseForInOf(lhs: NodeIdx) NodeIdx {
    const is_of = checkOf();
    advance(); // consume 'in' or 'of'
    // for-in RHS is an Expression (comma sequences allowed); for-of RHS is an
    // AssignmentExpression. BotGuard uses `for (x in a(), b, obj)` sequences.
    const rhs = if (is_of) parseAssignment() else parseExpression();
    expect(.rparen);
    const body = parseStatement();

    const node = allocNode(if (is_of) .for_of_stmt else .for_in_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = lhs;
    nodes[node].right = rhs;
    nodes[node].extra = body;
    return node;
}

fn parseWhileStmt() NodeIdx {
    advance(); // consume 'while'
    expect(.lparen);
    const cond = parseExpression();
    expect(.rparen);
    const body = parseStatement();

    const node = allocNode(.while_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = cond;
    nodes[node].right = body;
    return node;
}

fn parseDoWhileStmt() NodeIdx {
    advance(); // consume 'do'
    const body = parseStatement();
    if (!check(.kw_while)) { had_error = true; return NULL_NODE; }
    advance(); // consume 'while'
    expect(.lparen);
    const cond = parseExpression();
    expect(.rparen);
    consumeSemicolon();

    const node = allocNode(.do_while_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = cond;
    nodes[node].right = body;
    return node;
}

fn parseSwitchStmt() NodeIdx {
    advance(); // consume 'switch'
    expect(.lparen);
    const disc = parseExpression();
    expect(.rparen);
    expect(.lbrace);

    const node = allocNode(.switch_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = disc;

    var clauses: [256]NodeIdx = undefined;
    var count: u16 = 0;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        const clause = parseCaseClause();
        if (clause != NULL_NODE and count < 256) { clauses[count] = clause; count += 1; }
    }
    expect(.rbrace);
    nodes[node].right = commitList(clauses[0..count]);
    nodes[node].op = @intCast(@min(count, 255));
    return node;
}

fn parseCaseClause() NodeIdx {
    const is_default = check(.kw_default);
    if (!is_default and !check(.kw_case)) { had_error = true; return NULL_NODE; }
    advance(); // consume 'case' or 'default'

    const node = allocNode(.case_clause);
    if (node == NULL_NODE) return NULL_NODE;

    if (!is_default) {
        nodes[node].left = parseExpression();
    }
    expect(.colon);

    // Body statements until next case/default/}
    var stmts: [MAX_TOP_STMTS]NodeIdx = undefined;
    var count: usize = 0;
    while (!check(.kw_case) and !check(.kw_default) and !check(.rbrace) and !atEnd() and !had_error) {
        const stmt = parseStatement();
        if (stmt != NULL_NODE and count < MAX_TOP_STMTS) { stmts[count] = stmt; count += 1; }
    }
    nodes[node].right = commitList(stmts[0..count]);
    nodes[node].op = @intCast(@min(count, 255));
    return node;
}

fn parseTryStmt() NodeIdx {
    advance(); // consume 'try'
    const try_body = parseBlock();

    var catch_param: NodeIdx = NULL_NODE;
    var catch_body: NodeIdx = NULL_NODE;
    var finally_body: NodeIdx = NULL_NODE;

    if (check(.kw_catch)) {
        advance();
        if (check(.lparen)) {
            advance();
            catch_param = parseBindingPattern();
            expect(.rparen);
        }
        catch_body = parseBlock();
    }
    if (check(.kw_finally)) {
        advance();
        finally_body = parseBlock();
    }

    const node = allocNode(.try_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = try_body;
    nodes[node].right = catch_body;
    // Pack catch_param and finally in extra as a 2-item list.
    var cf: [2]NodeIdx = .{ catch_param, finally_body };
    nodes[node].extra = commitList(cf[0..2]);
    return node;
}

fn parseReturnStmt() NodeIdx {
    advance(); // consume 'return'
    const node = allocNode(.return_stmt);
    if (node == NULL_NODE) return NULL_NODE;

    if (!check(.semicolon) and !check(.rbrace) and !atEnd()) {
        // Check for ASI: if next token is on new line, treat as bare return
        if (!isNewlineBefore()) {
            nodes[node].left = parseExpression();
        }
    }
    consumeSemicolon();
    return node;
}

fn parseThrowStmt() NodeIdx {
    advance(); // consume 'throw'
    const node = allocNode(.throw_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = parseExpression();
    consumeSemicolon();
    return node;
}

fn parseBreakStmt() NodeIdx {
    advance(); // consume 'break'
    const node = allocNode(.break_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    if (check(.identifier) and !isNewlineBefore()) {
        nodes[node].token_idx = @intCast(tok_pos);
        advance();
    }
    consumeSemicolon();
    return node;
}

fn parseContinueStmt() NodeIdx {
    advance(); // consume 'continue'
    const node = allocNode(.continue_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    if (check(.identifier) and !isNewlineBefore()) {
        nodes[node].token_idx = @intCast(tok_pos);
        advance();
    }
    consumeSemicolon();
    return node;
}

fn parseWithStmt() NodeIdx {
    advance(); // consume 'with'
    expect(.lparen);
    const obj = parseExpression();
    expect(.rparen);
    const body = parseStatement();

    const node = allocNode(.with_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = obj;
    nodes[node].right = body;
    return node;
}

fn parseDebuggerStmt() NodeIdx {
    advance(); // consume 'debugger'
    consumeSemicolon();
    return allocNode(.debugger_stmt);
}

fn parseAsyncPrefix() NodeIdx {
    // 'async' could be: async function, async () =>, or just identifier 'async'
    if (tok_pos + 1 < tok_count) {
        const next = lexer.getToken(tok_pos + 1);
        if (next.tt == .kw_function) {
            advance(); // consume 'async'
            return parseFunctionFull(true, false);
        }
    }
    // Treat as expression statement (could be async arrow)
    return parseLabelOrExprStmt();
}

fn parseLabelOrExprStmt() NodeIdx {
    // Check for label: identifier followed by ':'
    if (check(.identifier) and tok_pos + 1 < tok_count) {
        const next = lexer.getToken(tok_pos + 1);
        if (next.tt == .colon) {
            const label = allocNode(.label_stmt);
            if (label != NULL_NODE) {
                nodes[label].token_idx = @intCast(tok_pos);
            }
            advance(); // identifier
            advance(); // colon
            if (label != NULL_NODE) {
                nodes[label].left = parseStatement();
            }
            return label;
        }
    }

    // Expression statement
    const expr = parseExpression();
    consumeSemicolon();

    const node = allocNode(.expr_stmt);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = expr;
    return node;
}

// ── Expression Parsing (Pratt Precedence) ──
//
// Precedence levels (lowest to highest):
//  1. Comma (sequence)
//  2. Assignment (=, +=, etc.)
//  3. Ternary (?:)
//  4. Nullish coalescing (??)
//  5. Logical OR (||)
//  6. Logical AND (&&)
//  7. Bitwise OR (|)
//  8. Bitwise XOR (^)
//  9. Bitwise AND (&)
// 10. Equality (==, !=, ===, !==)
// 11. Relational (<, >, <=, >=, instanceof, in)
// 12. Shift (<<, >>, >>>)
// 13. Additive (+, -)
// 14. Multiplicative (*, /, %)
// 15. Exponentiation (**)
// 16. Unary (!, ~, -, +, typeof, void, delete, ++, --, await)
// 17. Postfix (++, --)
// 18. Call, member access, new

fn parseExpression() NodeIdx {
    return parseSequence();
}

fn parseSequence() NodeIdx {
    var left = parseAssignment();
    if (check(.comma)) {
        // Check if this is actually a sequence expression (not in arg list etc.)
        // Sequence expressions are rare; handle by chaining
        while (check(.comma)) {
            advance();
            const right = parseAssignment();
            const seq = allocNode(.sequence_expr);
            if (seq == NULL_NODE) return left;
            nodes[seq].left = left;
            nodes[seq].right = right;
            left = seq;
        }
    }
    return left;
}

fn parseAssignment() NodeIdx {
    // Pratt: try to parse higher precedence, then check for assignment op
    const left = parseTernary();

    if (isAssignOp(peek().tt)) {
        const op = peek().tt;
        advance();
        const right = parseAssignment(); // right-associative
        const node = allocNode(.assign_expr);
        if (node == NULL_NODE) return left;
        nodes[node].left = left;
        nodes[node].right = right;
        nodes[node].op = @intFromEnum(op);
        return node;
    }
    return left;
}

fn parseTernary() NodeIdx {
    var cond = parseNullishCoalescing();
    if (check(.question)) {
        advance();
        const cons = parseAssignment();
        expect(.colon);
        const alt = parseAssignment();
        const node = allocNode(.cond_expr);
        if (node == NULL_NODE) return cond;
        nodes[node].left = cond;
        nodes[node].right = cons;
        nodes[node].extra = alt;
        cond = node;
    }
    return cond;
}

fn parseNullishCoalescing() NodeIdx {
    var left = parseLogicalOr();
    while (check(.nullish)) {
        advance();
        const right = parseLogicalOr();
        const node = allocNode(.logical_expr);
        if (node == NULL_NODE) return left;
        nodes[node].left = left;
        nodes[node].right = right;
        nodes[node].op = @intFromEnum(TokenType.nullish);
        left = node;
    }
    return left;
}

fn parseLogicalOr() NodeIdx {
    var left = parseLogicalAnd();
    while (check(.logical_or)) {
        advance();
        const right = parseLogicalAnd();
        const node = allocNode(.logical_expr);
        if (node == NULL_NODE) return left;
        nodes[node].left = left;
        nodes[node].right = right;
        nodes[node].op = @intFromEnum(TokenType.logical_or);
        left = node;
    }
    return left;
}

fn parseLogicalAnd() NodeIdx {
    var left = parseBitwiseOr();
    while (check(.logical_and)) {
        advance();
        const right = parseBitwiseOr();
        const node = allocNode(.logical_expr);
        if (node == NULL_NODE) return left;
        nodes[node].left = left;
        nodes[node].right = right;
        nodes[node].op = @intFromEnum(TokenType.logical_and);
        left = node;
    }
    return left;
}

fn parseBitwiseOr() NodeIdx {
    var left = parseBitwiseXor();
    while (check(.bit_or)) {
        advance();
        const right = parseBitwiseXor();
        left = makeBinary(left, right, .bit_or);
    }
    return left;
}

fn parseBitwiseXor() NodeIdx {
    var left = parseBitwiseAnd();
    while (check(.bit_xor)) {
        advance();
        const right = parseBitwiseAnd();
        left = makeBinary(left, right, .bit_xor);
    }
    return left;
}

fn parseBitwiseAnd() NodeIdx {
    var left = parseEquality();
    while (check(.bit_and)) {
        advance();
        const right = parseEquality();
        left = makeBinary(left, right, .bit_and);
    }
    return left;
}

fn parseEquality() NodeIdx {
    var left = parseRelational();
    while (check(.eq) or check(.neq) or check(.strict_eq) or check(.strict_neq)) {
        const op = peek().tt;
        advance();
        const right = parseRelational();
        left = makeBinary(left, right, op);
    }
    return left;
}

fn parseRelational() NodeIdx {
    var left = parseShift();
    while (check(.lt) or check(.gt) or check(.lte) or check(.gte) or check(.kw_instanceof) or (check(.kw_in) and !no_in)) {
        const op = peek().tt;
        advance();
        const right = parseShift();
        left = makeBinary(left, right, op);
    }
    return left;
}

fn parseShift() NodeIdx {
    var left = parseAdditive();
    while (check(.lshift) or check(.rshift) or check(.urshift)) {
        const op = peek().tt;
        advance();
        const right = parseAdditive();
        left = makeBinary(left, right, op);
    }
    return left;
}

fn parseAdditive() NodeIdx {
    var left = parseMultiplicative();
    while (check(.plus) or check(.minus)) {
        const op = peek().tt;
        advance();
        const right = parseMultiplicative();
        left = makeBinary(left, right, op);
    }
    return left;
}

fn parseMultiplicative() NodeIdx {
    var left = parseExponentiation();
    while (check(.star) or check(.slash) or check(.percent)) {
        const op = peek().tt;
        advance();
        const right = parseExponentiation();
        left = makeBinary(left, right, op);
    }
    return left;
}

fn parseExponentiation() NodeIdx {
    const base = parseUnary();
    if (check(.power)) {
        advance();
        const exp = parseExponentiation(); // right-associative
        return makeBinary(base, exp, .power);
    }
    return base;
}

fn parseUnary() NodeIdx {
    const tok = peek();
    switch (tok.tt) {
        .minus, .plus, .not, .bit_not => {
            advance();
            const operand = parseUnary();
            const node = allocNode(.unary_expr);
            if (node == NULL_NODE) return operand;
            nodes[node].op = @intFromEnum(tok.tt);
            nodes[node].left = operand;
            return node;
        },
        .kw_typeof => {
            advance();
            const operand = parseUnary();
            const node = allocNode(.typeof_expr);
            if (node == NULL_NODE) return operand;
            nodes[node].left = operand;
            return node;
        },
        .kw_void => {
            advance();
            const operand = parseUnary();
            const node = allocNode(.void_expr);
            if (node == NULL_NODE) return operand;
            nodes[node].left = operand;
            return node;
        },
        .kw_delete => {
            advance();
            const operand = parseUnary();
            const node = allocNode(.delete_expr);
            if (node == NULL_NODE) return operand;
            nodes[node].left = operand;
            return node;
        },
        .kw_await => {
            advance();
            const operand = parseUnary();
            const node = allocNode(.await_expr);
            if (node == NULL_NODE) return operand;
            nodes[node].left = operand;
            return node;
        },
        .kw_yield => {
            advance();
            const node = allocNode(.yield_expr);
            if (node == NULL_NODE) return NULL_NODE;
            if (!check(.semicolon) and !check(.rbrace) and !check(.rparen) and !check(.rbracket) and !check(.comma) and !atEnd()) {
                if (check(.star)) {
                    advance();
                    nodes[node].flags.is_generator = true;
                }
                nodes[node].left = parseAssignment();
            }
            return node;
        },
        .increment, .decrement => {
            advance();
            const operand = parseUnary();
            const node = allocNode(.unary_expr);
            if (node == NULL_NODE) return operand;
            nodes[node].op = @intFromEnum(tok.tt);
            nodes[node].left = operand;
            return node;
        },
        else => return parsePostfix(),
    }
}

fn parsePostfix() NodeIdx {
    var left = parseCallMemberNew();

    // Postfix ++ / --
    if ((check(.increment) or check(.decrement)) and !isNewlineBefore()) {
        const op = peek().tt;
        advance();
        const node = allocNode(.postfix_expr);
        if (node == NULL_NODE) return left;
        nodes[node].left = left;
        nodes[node].op = @intFromEnum(op);
        left = node;
    }
    return left;
}

fn parseCallMemberNew() NodeIdx {
    return parseLeftHandSide();
}

fn parseLeftHandSide() NodeIdx {
    var left: NodeIdx = undefined;

    if (check(.kw_new)) {
        left = parseNewExpr();
    } else {
        left = parsePrimary();
    }

    // Chained member access, calls, computed access, optional chaining
    while (true) {
        if (check(.dot)) {
            advance();
            const prop = allocNode(.identifier);
            if (prop != NULL_NODE) nodes[prop].token_idx = @intCast(tok_pos);
            if (check(.identifier) or isKeywordUsableAsProperty(peek().tt)) {
                advance();
            } else {
                had_error = true;
            }
            const member = allocNode(.member_expr);
            if (member == NULL_NODE) return left;
            nodes[member].left = left;
            nodes[member].right = prop;
            left = member;
        } else if (check(.lbracket)) {
            advance();
            const idx = parseExpression();
            expect(.rbracket);
            const comp = allocNode(.computed_expr);
            if (comp == NULL_NODE) return left;
            nodes[comp].left = left;
            nodes[comp].right = idx;
            left = comp;
        } else if (check(.lparen)) {
            left = parseCallArgs(left);
        } else if (check(.optional_chain)) {
            advance();
            const opt = allocNode(.optional_expr);
            if (opt == NULL_NODE) return left;
            nodes[opt].left = left;
            // ?. can be followed by identifier, [expr], or (args)
            if (check(.lparen)) {
                nodes[opt].right = parseCallArgs(left);
                // Re-wrap: the call's target should be the original left
                // Actually for ?. we just mark this node
            } else if (check(.lbracket)) {
                advance();
                nodes[opt].right = parseExpression();
                expect(.rbracket);
                nodes[opt].flags.is_computed = true;
            } else {
                const prop = allocNode(.identifier);
                if (prop != NULL_NODE) nodes[prop].token_idx = @intCast(tok_pos);
                advance();
                nodes[opt].right = prop;
            }
            left = opt;
        } else if (check(.template)) {
            // Tagged template literal: tag`str`
            const tmpl = allocNode(.literal_template);
            if (tmpl != NULL_NODE) nodes[tmpl].token_idx = @intCast(tok_pos);
            advance();
            const call = allocNode(.call_expr);
            if (call == NULL_NODE) return left;
            nodes[call].left = left;
            nodes[call].right = tmpl;
            left = call;
        } else {
            break;
        }
    }
    return left;
}

fn parseNewExpr() NodeIdx {
    advance(); // consume 'new'

    // new new F() — recursive
    if (check(.kw_new)) {
        const inner = parseNewExpr();
        const node = allocNode(.new_expr);
        if (node == NULL_NODE) return inner;
        nodes[node].left = inner;
        return node;
    }

    const callee = parsePrimary();
    // Chain member access on the constructor
    var target = callee;
    while (check(.dot) or check(.lbracket)) {
        if (check(.dot)) {
            advance();
            const prop = allocNode(.identifier);
            if (prop != NULL_NODE) nodes[prop].token_idx = @intCast(tok_pos);
            advance();
            const member = allocNode(.member_expr);
            if (member == NULL_NODE) return target;
            nodes[member].left = target;
            nodes[member].right = prop;
            target = member;
        } else {
            advance();
            const idx = parseExpression();
            expect(.rbracket);
            const comp = allocNode(.computed_expr);
            if (comp == NULL_NODE) return target;
            nodes[comp].left = target;
            nodes[comp].right = idx;
            target = comp;
        }
    }

    const node = allocNode(.new_expr);
    if (node == NULL_NODE) return target;
    nodes[node].left = target;

    // Optional arguments — gather locally, commit after all parsed.
    if (check(.lparen)) {
        advance();
        var args: [255]NodeIdx = undefined;
        var arg_count: u16 = 0;
        while (!check(.rparen) and !atEnd() and !had_error) {
            var item: NodeIdx = NULL_NODE;
            if (check(.spread)) {
                advance();
                const sp = allocNode(.spread_expr);
                if (sp != NULL_NODE) nodes[sp].left = parseAssignment();
                item = sp;
            } else {
                item = parseAssignment();
            }
            if (arg_count < 255) { args[arg_count] = item; arg_count += 1; }
            if (!check(.rparen)) expect(.comma);
        }
        expect(.rparen);
        nodes[node].right = commitList(args[0..arg_count]);
        nodes[node].op = @intCast(@min(arg_count, 255));
    }
    return node;
}

fn parseCallArgs(callee: NodeIdx) NodeIdx {
    advance(); // consume (
    const call = allocNode(.call_expr);
    if (call == NULL_NODE) return callee;
    nodes[call].left = callee;

    var args: [255]NodeIdx = undefined;
    var arg_count: u16 = 0;
    while (!check(.rparen) and !atEnd() and !had_error) {
        var item: NodeIdx = NULL_NODE;
        if (check(.spread)) {
            advance();
            const sp = allocNode(.spread_expr);
            if (sp != NULL_NODE) nodes[sp].left = parseAssignment();
            item = sp;
        } else {
            item = parseAssignment();
        }
        if (arg_count < 255) { args[arg_count] = item; arg_count += 1; }
        if (!check(.rparen)) expect(.comma);
    }
    expect(.rparen);
    nodes[call].right = commitList(args[0..arg_count]);
    nodes[call].op = @intCast(@min(arg_count, 255));
    return call;
}

// ── Primary Expressions ──

fn parsePrimary() NodeIdx {
    const tok = peek();
    switch (tok.tt) {
        .number => {
            const node = allocNode(.literal_num);
            if (node != NULL_NODE) nodes[node].token_idx = @intCast(tok_pos);
            advance();
            return node;
        },
        .string => {
            const node = allocNode(.literal_str);
            if (node != NULL_NODE) nodes[node].token_idx = @intCast(tok_pos);
            advance();
            return node;
        },
        .true_lit => {
            advance();
            return allocNode(.literal_bool);
        },
        .false_lit => {
            const node = allocNode(.literal_bool);
            if (node != NULL_NODE) nodes[node].op = 0; // false
            advance();
            return node;
        },
        .null_lit => { advance(); return allocNode(.literal_null); },
        .undefined_lit => { advance(); return allocNode(.literal_undef); },
        .regex => {
            const node = allocNode(.literal_regex);
            if (node != NULL_NODE) nodes[node].token_idx = @intCast(tok_pos);
            advance();
            return node;
        },
        .template => {
            const node = allocNode(.literal_template);
            if (node != NULL_NODE) nodes[node].token_idx = @intCast(tok_pos);
            advance();
            return node;
        },
        .kw_this => { advance(); return allocNode(.this_expr); },
        .identifier => return parseIdentifierOrArrow(),
        .lparen => return parseParenOrArrow(),
        .lbracket => return parseArrayExpr(),
        .lbrace => return parseObjectExpr(),
        .kw_function => return parseFunctionFull(false, true),
        .kw_class => return parseClassFull(true),
        .kw_async => return parseAsyncExpr(),
        else => {
            // Unknown primary — emit error node and advance
            had_error = true;
            advance();
            return NULL_NODE;
        },
    }
}

fn parseIdentifierOrArrow() NodeIdx {
    // Check for: ident => body (single-param arrow)
    if (tok_pos + 1 < tok_count) {
        const next = lexer.getToken(tok_pos + 1);
        if (next.tt == .arrow) {
            // Single-param arrow function
            const param = allocNode(.identifier);
            if (param != NULL_NODE) nodes[param].token_idx = @intCast(tok_pos);
            advance(); // consume ident
            advance(); // consume =>
            return parseArrowBody(param, 1);
        }
    }

    const node = allocNode(.identifier);
    if (node != NULL_NODE) nodes[node].token_idx = @intCast(tok_pos);
    advance();
    return node;
}

fn parseParenOrArrow() NodeIdx {
    // This is tricky: could be (expr), (a,b) => {}, or ()=>{}
    // Strategy: parse as parenthesized expr, then if followed by => reinterpret as arrow params

    const save_pos = tok_pos;
    const save_nodes = n_nodes;
    const save_list = list_used;

    advance(); // consume (

    // Empty parens => must be arrow
    if (check(.rparen)) {
        advance(); // consume )
        if (check(.arrow)) {
            advance(); // consume =>
            return parseArrowBody(NULL_NODE, 0);
        }
        // () without => is an error, but recover
        had_error = true;
        return NULL_NODE;
    }

    // Parse contents into a local buffer (each may push nested items into the
    // shared pool, so we cannot index the pool by position). If followed by
    // '=>' treat as arrow params, else as a grouped/sequence expression.
    var items: [64]NodeIdx = undefined;
    var param_count: u16 = 0;
    // Parse first item
    if (check(.spread)) {
        advance();
        const rest = allocNode(.spread_expr);
        if (rest != NULL_NODE) nodes[rest].left = parseBindingPattern();
        if (param_count < 64) { items[param_count] = rest; param_count += 1; }
    } else {
        const first = parseAssignment();
        if (param_count < 64) { items[param_count] = first; param_count += 1; }
    }

    while (check(.comma)) {
        advance();
        var item: NodeIdx = NULL_NODE;
        if (check(.spread)) {
            advance();
            const rest = allocNode(.spread_expr);
            if (rest != NULL_NODE) nodes[rest].left = parseBindingPattern();
            item = rest;
        } else {
            item = parseAssignment();
        }
        if (param_count < 64) { items[param_count] = item; param_count += 1; }
    }
    expect(.rparen);

    if (check(.arrow)) {
        advance(); // consume =>
        // Commit params contiguously and mark via a sequence_expr node.
        const params_start = commitList(items[0..param_count]);
        const params_node = allocNode(.sequence_expr); // reuse as param list marker
        if (params_node != NULL_NODE) {
            nodes[params_node].left = params_start;
            nodes[params_node].right = @intCast(param_count);
        }
        return parseArrowBody(params_node, param_count);
    }

    // Not an arrow — this was a parenthesized expression.
    _ = save_pos;
    _ = save_nodes;
    _ = save_list;
    if (param_count == 1) {
        return items[0];
    }

    // Multiple items without => : left-folded sequence expression.
    var result = items[0];
    for (1..param_count) |i| {
        const seq = allocNode(.sequence_expr);
        if (seq == NULL_NODE) return result;
        nodes[seq].left = result;
        nodes[seq].right = items[i];
        result = seq;
    }
    return result;
}

fn parseArrowBody(params: NodeIdx, param_count: u16) NodeIdx {
    const node = allocNode(.arrow_expr);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].token_idx = @intCast(tok_pos); // near `=>` (approx source pos)
    nodes[node].left = params;
    nodes[node].op = @intCast(@min(param_count, 255));

    // Body: block or single expression
    if (check(.lbrace)) {
        nodes[node].right = parseBlock();
    } else {
        nodes[node].right = parseAssignment();
    }
    if (tok_pos >= 1) { const et = lexer.getToken(tok_pos - 1); nodes[node].end_pos = et.start + et.len; }
    return node;
}

fn parseAsyncExpr() NodeIdx {
    // async function expr or async arrow
    if (tok_pos + 1 < tok_count) {
        const next = lexer.getToken(tok_pos + 1);
        if (next.tt == .kw_function) {
            advance(); // consume 'async'
            return parseFunctionFull(true, true);
        }
    }
    // Could be: async (params) => body or async ident => body
    advance(); // consume 'async'

    if (check(.lparen)) {
        const arrow = parseParenOrArrow();
        // Mark as async
        if (arrow != NULL_NODE and nodes[arrow].tag == .arrow_expr) {
            nodes[arrow].flags.is_async = true;
        }
        return arrow;
    }
    if (check(.identifier)) {
        if (tok_pos + 1 < tok_count and lexer.getToken(tok_pos + 1).tt == .arrow) {
            const param = allocNode(.identifier);
            if (param != NULL_NODE) nodes[param].token_idx = @intCast(tok_pos);
            advance(); // ident
            advance(); // =>
            const arrow = parseArrowBody(param, 1);
            if (arrow != NULL_NODE) nodes[arrow].flags.is_async = true;
            return arrow;
        }
    }
    // Fall back: 'async' as identifier
    const node = allocNode(.identifier);
    if (node != NULL_NODE) nodes[node].token_idx = @intCast(tok_pos -| 1);
    return node;
}

fn parseArrayExpr() NodeIdx {
    advance(); // consume [
    const node = allocNode(.array_expr);
    if (node == NULL_NODE) return NULL_NODE;

    var elems: [512]NodeIdx = undefined;
    var count: u16 = 0;
    while (!check(.rbracket) and !atEnd() and !had_error) {
        if (check(.comma)) {
            // Elision (hole)
            if (count < 512) { elems[count] = NULL_NODE; count += 1; }
            advance();
            continue;
        }
        var item: NodeIdx = NULL_NODE;
        if (check(.spread)) {
            advance();
            const sp = allocNode(.spread_expr);
            if (sp != NULL_NODE) nodes[sp].left = parseAssignment();
            item = sp;
        } else {
            item = parseAssignment();
        }
        if (count < 512) { elems[count] = item; count += 1; }
        if (!check(.rbracket)) {
            if (check(.comma)) { advance(); } else break;
        }
    }
    expect(.rbracket);
    nodes[node].left = commitList(elems[0..count]);
    nodes[node].right = @intCast(count);
    return node;
}

fn parseObjectExpr() NodeIdx {
    advance(); // consume {
    const node = allocNode(.object_expr);
    if (node == NULL_NODE) return NULL_NODE;

    var props: [512]NodeIdx = undefined;
    var count: u16 = 0;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        const prop = parseObjectProperty();
        if (prop != NULL_NODE and count < 512) { props[count] = prop; count += 1; }
        if (!check(.rbrace)) {
            if (check(.comma)) { advance(); } else break;
        }
    }
    expect(.rbrace);
    nodes[node].left = commitList(props[0..count]);
    nodes[node].right = @intCast(count);
    return node;
}

fn parseObjectProperty() NodeIdx {
    // Spread: ...expr
    if (check(.spread)) {
        advance();
        const sp = allocNode(.spread_expr);
        if (sp != NULL_NODE) nodes[sp].left = parseAssignment();
        return sp;
    }

    var flags = NodeFlags{};

    // get/set accessor
    if (checkIdentText("get") and !isPropertyValueNext()) {
        flags.is_getter = true;
        advance();
    } else if (checkIdentText("set") and !isPropertyValueNext()) {
        flags.is_setter = true;
        advance();
    }

    // Key: identifier, string, number, or [computed]
    var is_computed = false;
    const key: NodeIdx = blk: {
        if (check(.lbracket)) {
            is_computed = true;
            advance();
            const k = parseAssignment();
            expect(.rbracket);
            break :blk k;
        }
        if (check(.identifier) or check(.string) or check(.number) or isKeywordUsableAsProperty(peek().tt)) {
            const k = allocNode(if (check(.string)) .literal_str else if (check(.number)) .literal_num else .identifier);
            if (k != NULL_NODE) nodes[k].token_idx = @intCast(tok_pos);
            advance();
            break :blk k;
        }
        had_error = true;
        break :blk NULL_NODE;
    };
    flags.is_computed = is_computed;

    const prop = allocNode(.property);
    if (prop == NULL_NODE) return NULL_NODE;
    nodes[prop].flags = flags;
    nodes[prop].left = key;

    // Value
    if (check(.colon)) {
        advance();
        nodes[prop].right = parseAssignment();
    } else if (check(.lparen)) {
        // Method shorthand
        nodes[prop].right = parseMethodBody(false, false);
    } else {
        // Shorthand: { x } means { x: x }
        nodes[prop].right = key;
    }
    return prop;
}

// ── Helpers ──

fn makeBinary(left: NodeIdx, right: NodeIdx, op: TokenType) NodeIdx {
    const node = allocNode(.binary_expr);
    if (node == NULL_NODE) return left;
    nodes[node].left = left;
    nodes[node].right = right;
    nodes[node].op = @intFromEnum(op);
    return node;
}

fn allocNode(tag: NodeType) NodeIdx {
    if (n_nodes >= MAX_NODES) { had_error = true; return NULL_NODE; }
    const idx = n_nodes;
    nodes[idx] = .{ .tag = tag, .flags = .{} };
    // Set literal_bool true by default (false overrides)
    if (tag == .literal_bool) nodes[idx].op = 1;
    n_nodes += 1;
    return idx;
}

fn listPush(item: NodeIdx) void {
    if (list_used >= MAX_LIST_ITEMS) { had_error = true; return; }
    list_pool[list_used] = item;
    list_used += 1;
}

/// Commit a locally-gathered set of child indices contiguously into the list
/// pool and return the start offset. This isolates a collector from any
/// nested parsing that pushed into the pool while its children were being
/// parsed (the flat pool is shared across all collectors, so the naive
/// `list_used - list_start` span would incorrectly capture nested items).
fn commitList(items: []const NodeIdx) u32 {
    if (list_used + items.len > MAX_LIST_ITEMS) { had_error = true; return list_used; }
    const start: u32 = list_used;
    for (items) |it| {
        list_pool[list_used] = it;
        list_used += 1;
    }
    return start;
}

fn peek() Token {
    return lexer.getToken(tok_pos);
}

fn advance() void {
    if (tok_pos < tok_count) tok_pos += 1;
}

fn check(tt: TokenType) bool {
    return peek().tt == tt;
}

/// Contextual `of`: `of` tokenizes as an identifier (it's a valid variable name
/// in JS), so the for-loop parser recognizes the `for (x of y)` keyword form by
/// matching an identifier whose text is exactly "of". (`.kw_of` is also accepted
/// for safety, though the lexer no longer emits it.)
fn checkOf() bool {
    const t = peek();
    if (t.tt == .kw_of) return true;
    if (t.tt == .identifier) {
        const s = lexer.tokenText(t);
        return s.len == 2 and s[0] == 'o' and s[1] == 'f';
    }
    return false;
}

fn atEnd() bool {
    return peek().tt == .eof;
}

fn expect(tt: TokenType) void {
    if (check(tt)) {
        advance();
    } else {
        had_error = true;
    }
}

fn consumeSemicolon() void {
    if (check(.semicolon)) { advance(); return; }
    // ASI: allow missing semicolons before }, at EOF, or after newline
    if (check(.rbrace) or atEnd() or isNewlineBefore()) return;
    // Otherwise it's an error, but be lenient for BotGuard's minified code
    // (don't set had_error — just skip)
}

fn isNewlineBefore() bool {
    // Check if there's a newline between prev token end and current token start
    if (tok_pos == 0) return false;
    const prev = lexer.getToken(tok_pos - 1);
    const curr = peek();
    const gap_start = prev.start + prev.len;
    const gap_end = curr.start;
    if (gap_end <= gap_start) return false;
    // In minified BotGuard code there are no significant newlines.
    // For correctness we'd scan source bytes for \n in [gap_start..gap_end],
    // but the lexer doesn't expose the source buffer to us directly here.
    // Conservative: assume no newline (BotGuard is minified, no ASI reliance).
    return false;
}

fn isAssignOp(tt: TokenType) bool {
    return switch (tt) {
        .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign,
        .percent_assign, .power_assign, .amp_assign, .pipe_assign,
        .caret_assign, .lshift_assign, .rshift_assign, .urshift_assign,
        .nullish_assign, .and_assign, .or_assign => true,
        else => false,
    };
}

fn isKeywordUsableAsProperty(tt: TokenType) bool {
    // In JS, most keywords can be used as property names
    return switch (tt) {
        .kw_var, .kw_let, .kw_const, .kw_function, .kw_return, .kw_if, .kw_else,
        .kw_for, .kw_while, .kw_do, .kw_break, .kw_continue, .kw_switch,
        .kw_case, .kw_default, .kw_new, .kw_this, .kw_typeof, .kw_instanceof,
        .kw_in, .kw_of, .kw_delete, .kw_void, .kw_throw, .kw_try, .kw_catch,
        .kw_finally, .kw_class, .kw_extends, .kw_super, .kw_import, .kw_export,
        .kw_async, .kw_await, .kw_yield, .kw_with, .kw_debugger,
        // Literal keywords are also valid property names: obj.true, x.null, etc.
        .true_lit, .false_lit, .null_lit, .undefined_lit => true,
        else => false,
    };
}

fn checkIdentText(text: []const u8) bool {
    if (!check(.identifier)) return false;
    const tok = peek();
    const src = lexer.tokenText(tok);
    return eql(src, text);
}

fn isPropertyValueNext() bool {
    // After get/set keyword, if next is : or ( then this is a regular property named get/set
    if (tok_pos + 1 >= tok_count) return true;
    const next = lexer.getToken(tok_pos + 1);
    return next.tt == .colon or next.tt == .comma or next.tt == .rbrace;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}
