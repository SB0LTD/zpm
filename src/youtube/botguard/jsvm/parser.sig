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
    token_idx: u16 = 0, // index of primary token (for error reporting / literal value)
    left: NodeIdx = NULL_NODE, // left child / condition / first param
    right: NodeIdx = NULL_NODE, // right child / consequent
    extra: NodeIdx = NULL_NODE, // alternate / third child / extra info
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

pub const NodeIdx = u16;
pub const NULL_NODE: NodeIdx = 0xFFFF;

/// Maximum AST nodes (~256KB with 20-byte nodes = ~13000 nodes).
pub const MAX_NODES: usize = 13000;

/// List pool — for variable-length child lists (params, args, stmts, etc.)
/// Each list entry is a NodeIdx. Lists are contiguous ranges in this pool.
pub const MAX_LIST_ITEMS: usize = 32000;

// ── Parser State ──

var nodes: [MAX_NODES]Node = undefined;
var n_nodes: u16 = 0;

/// List pool: flat array of NodeIdx values.
/// Lists are referenced by (start, len) stored in a node's left/right fields.
var list_pool: [MAX_LIST_ITEMS]NodeIdx = undefined;
var list_used: u16 = 0;

var tok_pos: usize = 0; // current token index
var tok_count: usize = 0; // total tokens from lexer
var had_error: bool = false;

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

    // Parse top-level statements into a list
    const list_start = list_used;
    while (!atEnd() and !had_error) {
        const stmt = parseStatement();
        if (stmt != NULL_NODE) {
            listPush(stmt);
        }
    }
    const list_len = list_used - list_start;

    nodes[root].left = list_start;
    nodes[root].right = @intCast(list_len);
    return root;
}

/// Get a parsed node.
pub fn getNode(idx: NodeIdx) Node {
    if (idx == NULL_NODE or idx >= n_nodes) return .{ .tag = .empty_stmt, .flags = .{} };
    return nodes[idx];
}

/// Get a slice of the list pool.
pub fn getList(start: u16, len: u16) []const NodeIdx {
    if (start + len > list_used) return &[_]NodeIdx{};
    return list_pool[start .. start + len];
}

/// Get total node count.
pub fn nodeCount() u16 {
    return n_nodes;
}

/// Whether a parse error occurred.
pub fn hasError() bool {
    return had_error;
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

    const list_start = list_used;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        const stmt = parseStatement();
        if (stmt != NULL_NODE) listPush(stmt);
    }
    expect(.rbrace);
    const list_len = list_used - list_start;

    nodes[node].left = list_start;
    nodes[node].right = @intCast(list_len);
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

    // Parse declarators as a list: each entry is [name, init] pair as two list items
    const list_start = list_used;
    var count: u16 = 0;
    while (true) {
        // Name (or destructuring pattern — for now just identifiers)
        const name = parseBindingPattern();
        listPush(name);
        count += 1;

        // Optional initializer
        if (check(.assign)) {
            advance(); // consume =
            const init = parseAssignment();
            listPush(init);
            count += 1;
        } else {
            listPush(NULL_NODE);
            count += 1;
        }

        if (!check(.comma)) break;
        advance(); // consume ,
    }
    consumeSemicolon();

    nodes[node].left = list_start;
    nodes[node].right = @intCast(count);
    return node;
}

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
    advance(); // consume 'function'
    const is_gen = check(.star);
    if (is_gen) advance(); // consume *

    const node = allocNode(if (is_expr) .func_expr else .func_decl);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].flags = .{ .is_async = is_async, .is_generator = is_gen };

    // Optional name
    if (check(.identifier)) {
        const name = allocNode(.identifier);
        if (name != NULL_NODE) nodes[name].token_idx = @intCast(tok_pos);
        advance();
        nodes[node].left = name;
    }

    // Parameters
    expect(.lparen);
    const params_start = list_used;
    var param_count: u16 = 0;
    while (!check(.rparen) and !atEnd() and !had_error) {
        if (check(.spread)) {
            advance();
            const rest = allocNode(.spread_expr);
            if (rest != NULL_NODE) {
                nodes[rest].left = parseBindingPattern();
            }
            listPush(rest);
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
                listPush(pair);
            } else {
                listPush(param);
            }
        }
        param_count += 1;
        if (!check(.rparen)) expect(.comma);
    }
    expect(.rparen);
    nodes[node].extra = params_start;
    nodes[node].op = @intCast(param_count);

    // Body (must be a block)
    nodes[node].right = parseBlock();
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

    // Body { ... }
    expect(.lbrace);
    const list_start = list_used;
    var count: u16 = 0;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        if (check(.semicolon)) { advance(); continue; }
        const member = parseClassMember();
        if (member != NULL_NODE) { listPush(member); count += 1; }
    }
    expect(.rbrace);
    nodes[node].right = list_start;
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
    nodes[node].flags = .{ .is_async = is_async, .is_generator = is_gen };

    expect(.lparen);
    const params_start = list_used;
    var param_count: u16 = 0;
    while (!check(.rparen) and !atEnd() and !had_error) {
        if (check(.spread)) {
            advance();
            const rest = allocNode(.spread_expr);
            if (rest != NULL_NODE) nodes[rest].left = parseBindingPattern();
            listPush(rest);
        } else {
            const param = parseBindingPattern();
            if (check(.assign)) {
                advance();
                const def = parseAssignment();
                const pair = allocNode(.assign_expr);
                if (pair != NULL_NODE) { nodes[pair].left = param; nodes[pair].right = def; }
                listPush(pair);
            } else {
                listPush(param);
            }
        }
        param_count += 1;
        if (!check(.rparen)) expect(.comma);
    }
    expect(.rparen);
    nodes[node].extra = params_start;
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

    // Could be: for(init;cond;update), for(x in obj), for(x of iter)
    var init: NodeIdx = NULL_NODE;
    if (check(.semicolon)) {
        advance(); // empty init
    } else if (check(.kw_var) or check(.kw_let) or check(.kw_const)) {
        // var decl without semicolon — check for in/of after first declarator
        init = parseForVarDecl();
        if (init != NULL_NODE and (check(.kw_in) or check(.kw_of))) {
            return parseForInOf(init);
        }
        expect(.semicolon);
    } else {
        init = parseExpression();
        if (check(.kw_in) or check(.kw_of)) {
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
    // Store cond and update in extra using list
    const extra_start = list_used;
    listPush(cond);
    listPush(update);
    nodes[node].extra = extra_start;
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

    const list_start = list_used;
    const name = parseBindingPattern();
    listPush(name);

    if (check(.assign)) {
        advance();
        const init = parseAssignment();
        listPush(init);
    } else {
        listPush(NULL_NODE);
    }

    nodes[node].left = list_start;
    nodes[node].right = 2; // one declarator = 2 list items
    return node;
}

fn parseForInOf(lhs: NodeIdx) NodeIdx {
    const is_of = check(.kw_of);
    advance(); // consume 'in' or 'of'
    const rhs = parseAssignment();
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

    const list_start = list_used;
    var count: u16 = 0;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        const clause = parseCaseClause();
        if (clause != NULL_NODE) { listPush(clause); count += 1; }
    }
    expect(.rbrace);
    nodes[node].right = list_start;
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
    const list_start = list_used;
    var count: u16 = 0;
    while (!check(.kw_case) and !check(.kw_default) and !check(.rbrace) and !atEnd() and !had_error) {
        const stmt = parseStatement();
        if (stmt != NULL_NODE) { listPush(stmt); count += 1; }
    }
    nodes[node].right = list_start;
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
    // Pack catch_param and finally in extra via list
    const extra_start = list_used;
    listPush(catch_param);
    listPush(finally_body);
    nodes[node].extra = extra_start;
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
    while (check(.lt) or check(.gt) or check(.lte) or check(.gte) or check(.kw_instanceof) or check(.kw_in)) {
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

    // Optional arguments
    if (check(.lparen)) {
        advance();
        const list_start = list_used;
        var arg_count: u16 = 0;
        while (!check(.rparen) and !atEnd() and !had_error) {
            if (check(.spread)) {
                advance();
                const sp = allocNode(.spread_expr);
                if (sp != NULL_NODE) nodes[sp].left = parseAssignment();
                listPush(sp);
            } else {
                listPush(parseAssignment());
            }
            arg_count += 1;
            if (!check(.rparen)) expect(.comma);
        }
        expect(.rparen);
        nodes[node].right = list_start;
        nodes[node].op = @intCast(@min(arg_count, 255));
    }
    return node;
}

fn parseCallArgs(callee: NodeIdx) NodeIdx {
    advance(); // consume (
    const call = allocNode(.call_expr);
    if (call == NULL_NODE) return callee;
    nodes[call].left = callee;

    const list_start = list_used;
    var arg_count: u16 = 0;
    while (!check(.rparen) and !atEnd() and !had_error) {
        if (check(.spread)) {
            advance();
            const sp = allocNode(.spread_expr);
            if (sp != NULL_NODE) nodes[sp].left = parseAssignment();
            listPush(sp);
        } else {
            listPush(parseAssignment());
        }
        arg_count += 1;
        if (!check(.rparen)) expect(.comma);
    }
    expect(.rparen);
    nodes[call].right = list_start;
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

    // Try parsing params for arrow detection
    // Parse contents — if followed by '=>' treat as arrow, else as grouped expr
    const list_start = list_used;
    var param_count: u16 = 0;
    // Parse first item
    if (check(.spread)) {
        advance();
        const rest = allocNode(.spread_expr);
        if (rest != NULL_NODE) nodes[rest].left = parseBindingPattern();
        listPush(rest);
        param_count += 1;
        // Rest param means this must be arrow params
    } else {
        const first = parseAssignment();
        listPush(first);
        param_count += 1;
    }

    while (check(.comma)) {
        advance();
        if (check(.spread)) {
            advance();
            const rest = allocNode(.spread_expr);
            if (rest != NULL_NODE) nodes[rest].left = parseBindingPattern();
            listPush(rest);
            param_count += 1;
        } else {
            listPush(parseAssignment());
            param_count += 1;
        }
    }
    expect(.rparen);

    if (check(.arrow)) {
        advance(); // consume =>
        // Params are in list_pool[list_start..list_start+param_count]
        // Create a "params" marker node
        const params_node = allocNode(.sequence_expr); // reuse as param list marker
        if (params_node != NULL_NODE) {
            nodes[params_node].left = list_start;
            nodes[params_node].right = @intCast(param_count);
        }
        return parseArrowBody(params_node, param_count);
    }

    // Not an arrow — this was a parenthesized expression
    // If we only had one item, it's just (expr)
    if (param_count == 1) {
        // The expression is list_pool[list_start]
        _ = save_pos;
        _ = save_nodes;
        _ = save_list;
        return list_pool[list_start];
    }

    // Multiple items without => : this is a sequence expression
    var result = list_pool[list_start];
    for (1..param_count) |i| {
        const right = list_pool[list_start + @as(u16, @intCast(i))];
        const seq = allocNode(.sequence_expr);
        if (seq == NULL_NODE) return result;
        nodes[seq].left = result;
        nodes[seq].right = right;
        result = seq;
    }
    return result;
}

fn parseArrowBody(params: NodeIdx, param_count: u16) NodeIdx {
    const node = allocNode(.arrow_expr);
    if (node == NULL_NODE) return NULL_NODE;
    nodes[node].left = params;
    nodes[node].op = @intCast(@min(param_count, 255));

    // Body: block or single expression
    if (check(.lbrace)) {
        nodes[node].right = parseBlock();
    } else {
        nodes[node].right = parseAssignment();
    }
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

    const list_start = list_used;
    var count: u16 = 0;
    while (!check(.rbracket) and !atEnd() and !had_error) {
        if (check(.comma)) {
            // Elision (hole)
            listPush(NULL_NODE);
            count += 1;
            advance();
            continue;
        }
        if (check(.spread)) {
            advance();
            const sp = allocNode(.spread_expr);
            if (sp != NULL_NODE) nodes[sp].left = parseAssignment();
            listPush(sp);
        } else {
            listPush(parseAssignment());
        }
        count += 1;
        if (!check(.rbracket)) {
            if (check(.comma)) { advance(); } else break;
        }
    }
    expect(.rbracket);
    nodes[node].left = list_start;
    nodes[node].right = @intCast(count);
    return node;
}

fn parseObjectExpr() NodeIdx {
    advance(); // consume {
    const node = allocNode(.object_expr);
    if (node == NULL_NODE) return NULL_NODE;

    const list_start = list_used;
    var count: u16 = 0;
    while (!check(.rbrace) and !atEnd() and !had_error) {
        const prop = parseObjectProperty();
        if (prop != NULL_NODE) { listPush(prop); count += 1; }
        if (!check(.rbrace)) {
            if (check(.comma)) { advance(); } else break;
        }
    }
    expect(.rbrace);
    nodes[node].left = list_start;
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

fn peek() Token {
    return lexer.getToken(tok_pos);
}

fn advance() void {
    if (tok_pos < tok_count) tok_pos += 1;
}

fn check(tt: TokenType) bool {
    return peek().tt == tt;
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
        .kw_async, .kw_await, .kw_yield, .kw_with, .kw_debugger => true,
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
