// @zpm/youtube/botguard/jsvm/compiler — AST → Bytecode Compiler
//
// Walks the parser's AST and emits a flat bytecode stream for the VM.
// Stack-based architecture: all operations push/pop from an operand stack.
// Supports: scopes (lexical + function), closures, exception frames, loops.
//
// Bytecode format: 1-byte opcode + 0-2 operand bytes (u16 LE where needed).
// Maximum bytecode size: 512KB (sufficient for 500KB minified JS).

const parser = @import("parser.sig");
const values = @import("values.sig");
const lexer = @import("lexer.sig");
const Node = parser.Node;
const NodeType = parser.NodeType;
const NodeIdx = parser.NodeIdx;
const NULL_NODE = parser.NULL_NODE;
const TokenType = lexer.TokenType;

// ── Opcodes ──

pub const Op = enum(u8) {
    // Stack manipulation
    nop,
    pop, // discard TOS
    dup, // duplicate TOS
    swap, // swap top two

    // Constants / literals
    load_const, // u16: constant index → push value
    load_undef, // push undefined
    load_null, // push null
    load_true, // push true
    load_false, // push false
    load_zero, // push 0
    load_one, // push 1

    // Variables
    get_local, // u16: slot → push local
    set_local, // u16: slot → pop value into local
    get_upval, // u16: upvalue index → push captured var
    set_upval, // u16: upvalue index → pop into captured var
    get_global, // u16: name constant index → push global[name]
    set_global, // u16: name constant index → global[name] = pop
    def_global, // u16: name constant index → define global (var decl)

    // Property access
    get_prop, // u16: name constant index → obj.name
    set_prop, // u16: name constant index → obj.name = val
    get_elem, // [obj, key] → obj[key]
    set_elem, // [obj, key, val] → obj[key] = val
    get_optional, // u16: name → obj?.name (null-safe)
    get_elem_optional, // [obj, key] → obj?.[key]

    // Arithmetic
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %
    pow, // **
    neg, // unary -
    pos, // unary + (toNumber)

    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    bit_not,
    shl,
    shr,
    ushr,

    // Comparison
    eq, // ==
    neq, // !=
    seq, // ===
    sneq, // !==
    lt, // <
    gt, // >
    lte, // <=
    gte, // >=
    instanceof,
    in_op,

    // Logical
    not, // !
    typeof_op, // typeof (doesn't throw on undefined)
    void_op, // void expr → undefined
    delete_op, // delete obj.prop

    // Control flow
    jump, // u16: offset → unconditional jump
    jump_if_false, // u16: offset → pop, jump if falsy
    jump_if_true, // u16: offset → pop, jump if truthy
    jump_nullish, // u16: offset → peek, jump if null/undefined (for ??)
    loop_back, // u16: offset → jump backwards

    // Functions and calls
    call, // u8: argc → call TOS-argc with argc args
    call_method, // u16: name const + u8: argc → obj.method(args)
    ret, // return TOS
    ret_undef, // return undefined

    // Object/Array construction
    make_object, // u8: prop_count → create object with N props from stack
    make_array, // u16: elem_count → create array from stack
    make_func, // u16: func_descriptor index → create closure

    // Special
    spread, // mark spread arg in call/array
    new_call, // u8: argc → new Constructor(args)
    this_val, // push this
    throw_op, // throw TOS
    enter_try, // u16: catch_offset, u16: finally_offset
    leave_try, // exit try frame
    enter_catch, // push caught exception
    enter_finally, // enter finally block
    leave_finally, // exit finally (re-throw if pending)

    // Iteration / for-in / for-of
    iter_init, // init iterator from TOS
    iter_next, // push next value (or jump u16 if done)
    iter_close, // close iterator

    // Increment / decrement
    pre_inc, // ++x
    pre_dec, // --x
    post_inc, // x++
    post_dec, // x--

    // Misc
    debugger_op,
    halt, // end of program
};

// ── Constant pool ──

pub const MAX_CONSTANTS: usize = 16384;
pub const MAX_BYTECODE: usize = 512 * 1024; // 512KB
pub const MAX_FUNCTIONS: usize = 4096;

/// A constant value (number or string index).
pub const Constant = struct {
    is_string: bool = false,
    num: f64 = 0,
    str_idx: u32 = 0,
};

/// A function descriptor (for make_func).
pub const FuncDesc = struct {
    code_start: u32 = 0, // offset into bytecode where function body starts
    code_len: u32 = 0,
    param_count: u8 = 0,
    local_count: u16 = 0,
    upval_count: u8 = 0,
    name_const: u16 = 0, // constant index for function name (or 0xFFFF)
    is_arrow: bool = false,
    is_async: bool = false,
    is_generator: bool = false,
};

// ── Scope tracking ──

const MAX_LOCALS: usize = 256;
const MAX_SCOPES: usize = 32;
const MAX_UPVALS: usize = 64;
const MAX_BREAKS: usize = 64;
const MAX_CONTINUES: usize = 64;

const Local = struct {
    name_start: u32 = 0, // offset into source for name
    name_len: u16 = 0,
    depth: u16 = 0, // scope depth
    is_captured: bool = false,
};

const Upvalue = struct {
    index: u8 = 0, // local index in enclosing scope (or upval index if !is_local)
    is_local: bool = true,
};

// ── Compiler State ──

var bytecode: [MAX_BYTECODE]u8 = undefined;
var bc_len: u32 = 0;

var constants: [MAX_CONSTANTS]Constant = undefined;
var n_constants: u16 = 0;

var functions: [MAX_FUNCTIONS]FuncDesc = undefined;
var n_functions: u16 = 0;

var locals: [MAX_LOCALS]Local = undefined;
var local_count: u16 = 0;
var scope_depth: u16 = 0;

var upvals: [MAX_UPVALS]Upvalue = undefined;
var upval_count: u8 = 0;

// Break/continue patch lists
var break_patches: [MAX_BREAKS]u32 = undefined;
var break_count: u16 = 0;
var continue_patches: [MAX_CONTINUES]u32 = undefined;
var continue_count: u16 = 0;
var loop_start: u32 = 0; // bytecode offset of current loop start

var had_error: bool = false;

// ── Public API ──

/// Compile the parsed AST into bytecode.
/// Call after parser.parse() has been invoked.
/// Returns bytecode length (0 on failure).
pub fn compile(root: NodeIdx) u32 {
    bc_len = 0;
    n_constants = 0;
    n_functions = 0;
    local_count = 0;
    scope_depth = 0;
    upval_count = 0;
    break_count = 0;
    continue_count = 0;
    loop_start = 0;
    had_error = false;

    compileNode(root);
    emitOp(.halt);
    return bc_len;
}

/// Get the compiled bytecode.
pub fn getBytecode() []const u8 {
    return bytecode[0..bc_len];
}

/// Get a constant by index.
pub fn getConstant(idx: u16) Constant {
    if (idx >= n_constants) return .{};
    return constants[idx];
}

/// Get a function descriptor.
pub fn getFunction(idx: u16) FuncDesc {
    if (idx >= n_functions) return .{};
    return functions[idx];
}

/// Get total constants count.
pub fn constantCount() u16 {
    return n_constants;
}

/// Get total functions count.
pub fn functionCount() u16 {
    return n_functions;
}

/// Whether compilation encountered an error.
pub fn hasError() bool {
    return had_error;
}

// ── Node Compilation ──

fn compileNode(idx: NodeIdx) void {
    if (idx == NULL_NODE or had_error) return;
    const node = parser.getNode(idx);

    switch (node.tag) {
        .program => compileProgram(node),
        .block => compileBlock(node),
        .var_decl => compileVarDecl(node),
        .func_decl => compileFuncDecl(node),
        .class_decl => compileClassDecl(node),
        .if_stmt => compileIf(node),
        .for_stmt => compileFor(node),
        .for_in_stmt => compileForIn(node),
        .for_of_stmt => compileForOf(node),
        .while_stmt => compileWhile(node),
        .do_while_stmt => compileDoWhile(node),
        .switch_stmt => compileSwitch(node),
        .try_stmt => compileTry(node),
        .return_stmt => compileReturn(node),
        .throw_stmt => compileThrow(node),
        .break_stmt => compileBreak(),
        .continue_stmt => compileContinue(),
        .expr_stmt => compileExprStmt(node),
        .empty_stmt => {},
        .debugger_stmt => emitOp(.debugger_op),
        .label_stmt => compileLabelStmt(node),
        .with_stmt => compileWithStmt(node),

        // Expressions
        .literal_num => compileLiteralNum(node),
        .literal_str => compileLiteralStr(node),
        .literal_bool => compileLiteralBool(node),
        .literal_null => emitOp(.load_null),
        .literal_undef => emitOp(.load_undef),
        .literal_regex => compileLiteralStr(node), // treat as string for now
        .literal_template => compileLiteralStr(node),
        .identifier => compileIdentifier(node),
        .this_expr => emitOp(.this_val),
        .array_expr => compileArray(node),
        .object_expr => compileObject(node),
        .func_expr => compileFuncExpr(node),
        .arrow_expr => compileArrow(node),
        .class_expr => compileClassDecl(node),
        .unary_expr => compileUnary(node),
        .postfix_expr => compilePostfix(node),
        .binary_expr => compileBinary(node),
        .logical_expr => compileLogical(node),
        .assign_expr => compileAssign(node),
        .cond_expr => compileCond(node),
        .call_expr => compileCall(node),
        .new_expr => compileNew(node),
        .member_expr => compileMember(node),
        .computed_expr => compileComputed(node),
        .optional_expr => compileOptional(node),
        .sequence_expr => compileSequence(node),
        .spread_expr => compileSpread(node),
        .typeof_expr => compileTypeof(node),
        .void_expr => compileVoid(node),
        .delete_expr => compileDelete(node),
        .yield_expr => compileYield(node),
        .await_expr => compileAwait(node),
        else => {},
    }
}

// ── Statement Compilation ──

fn compileProgram(node: Node) void {
    const list = parser.getList(node.left, @intCast(node.right));
    for (list) |stmt_idx| {
        compileNode(stmt_idx);
    }
}

fn compileBlock(node: Node) void {
    beginScope();
    const list = parser.getList(node.left, @intCast(node.right));
    for (list) |stmt_idx| {
        compileNode(stmt_idx);
    }
    endScope();
}

fn compileVarDecl(node: Node) void {
    const list = parser.getList(node.left, @intCast(node.right));
    // List is pairs: [name, init, name, init, ...]
    var i: usize = 0;
    while (i + 1 < list.len) : (i += 2) {
        const name_idx = list[i];
        const init_idx = list[i + 1];

        if (init_idx != NULL_NODE) {
            compileNode(init_idx);
        } else {
            emitOp(.load_undef);
        }

        // Declare variable
        if (scope_depth > 0) {
            // Local variable
            declareLocal(name_idx);
            emitOp(.set_local);
            emitU16(local_count -| 1);
            emitOp(.pop); // set_local doesn't pop in our model, so we leave val; actually let's not pop — adjust
        } else {
            // Global variable
            const name_const = nameConstant(name_idx);
            emitOp(.def_global);
            emitU16(name_const);
        }
    }
}

fn compileFuncDecl(node: Node) void {
    // Compile function body into a FuncDesc
    const func_idx = compileFunctionBody(node);

    // Create the closure and bind to name
    emitOp(.make_func);
    emitU16(func_idx);

    if (scope_depth > 0) {
        declareLocal(node.left); // name node
        emitOp(.set_local);
        emitU16(local_count -| 1);
    } else {
        const name_const = nameConstant(node.left);
        emitOp(.def_global);
        emitU16(name_const);
    }
}

fn compileClassDecl(node: Node) void {
    // Simplified class: compile as an object factory
    // Push constructor function (or empty), set prototype methods

    // If extends, compile superclass
    if (node.extra != NULL_NODE) {
        compileNode(node.extra);
    } else {
        emitOp(.load_null);
    }

    // Compile class body members
    const count = node.op;
    const list = parser.getList(node.right, @intCast(count));
    for (list) |member_idx| {
        if (member_idx != NULL_NODE) {
            compileNode(member_idx);
        }
    }

    emitOp(.make_object);
    emitByte(@intCast(count));

    // Bind name if present
    if (node.left != NULL_NODE) {
        if (scope_depth > 0) {
            declareLocal(node.left);
            emitOp(.set_local);
            emitU16(local_count -| 1);
        } else {
            const name_const = nameConstant(node.left);
            emitOp(.def_global);
            emitU16(name_const);
        }
    }
}

fn compileIf(node: Node) void {
    compileNode(node.left); // condition
    const jump_false = emitJump(.jump_if_false);

    compileNode(node.right); // consequent

    if (node.extra != NULL_NODE) {
        const jump_end = emitJump(.jump);
        patchJump(jump_false);
        compileNode(node.extra); // alternate
        patchJump(jump_end);
    } else {
        patchJump(jump_false);
    }
}

fn compileFor(node: Node) void {
    beginScope();

    // Init
    compileNode(node.left);

    // Condition + update stored in extra list
    const extras = parser.getList(node.extra, 2);
    const cond_idx = if (extras.len > 0) extras[0] else NULL_NODE;
    const update_idx = if (extras.len > 1) extras[1] else NULL_NODE;

    const saved_loop = loop_start;
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    loop_start = bc_len;

    // Condition
    var exit_jump: u32 = 0;
    if (cond_idx != NULL_NODE) {
        compileNode(cond_idx);
        exit_jump = emitJump(.jump_if_false);
    }

    // Body
    compileNode(node.right);

    // Continue target
    const continue_target = bc_len;

    // Update
    if (update_idx != NULL_NODE) {
        compileNode(update_idx);
        emitOp(.pop);
    }

    // Loop back
    emitLoop(loop_start);

    // Exit
    if (cond_idx != NULL_NODE) {
        patchJump(exit_jump);
    }

    patchBreaks(saved_breaks);
    patchContinues(saved_continues, continue_target);
    loop_start = saved_loop;
    endScope();
}

fn compileForIn(node: Node) void {
    beginScope();
    compileNode(node.right); // the object to iterate
    emitOp(.iter_init);

    const saved_loop = loop_start;
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    loop_start = bc_len;

    const exit_jump = emitJump(.iter_next);

    // Assign key to LHS
    if (node.left != NULL_NODE) {
        const lhs_node = parser.getNode(node.left);
        if (lhs_node.tag == .var_decl) {
            const vlist = parser.getList(lhs_node.left, @intCast(lhs_node.right));
            if (vlist.len > 0) {
                declareLocal(vlist[0]);
                emitOp(.set_local);
                emitU16(local_count -| 1);
            }
        } else {
            emitOp(.pop); // simplified
        }
    }

    compileNode(node.extra); // body
    emitLoop(loop_start);
    patchJump(exit_jump);
    emitOp(.iter_close);

    patchBreaks(saved_breaks);
    patchContinues(saved_continues, loop_start);
    loop_start = saved_loop;
    endScope();
}

fn compileForOf(node: Node) void {
    // Same structure as for-in but with different iteration semantics
    compileForIn(node); // reuse — VM differentiates via iter_init behavior
}

fn compileWhile(node: Node) void {
    const saved_loop = loop_start;
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    loop_start = bc_len;

    compileNode(node.left); // condition
    const exit_jump = emitJump(.jump_if_false);

    compileNode(node.right); // body
    emitLoop(loop_start);
    patchJump(exit_jump);

    patchBreaks(saved_breaks);
    patchContinues(saved_continues, loop_start);
    loop_start = saved_loop;
}

fn compileDoWhile(node: Node) void {
    const saved_loop = loop_start;
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    loop_start = bc_len;

    compileNode(node.right); // body

    const continue_target = bc_len;
    compileNode(node.left); // condition
    // Jump back if true
    const cond_jump = emitJump(.jump_if_true);
    _ = cond_jump;
    // Patch to loop start
    patchJumpTo(bc_len - 2, loop_start);

    patchBreaks(saved_breaks);
    patchContinues(saved_continues, continue_target);
    loop_start = saved_loop;
}

fn compileSwitch(node: Node) void {
    compileNode(node.left); // discriminant

    const count = node.op;
    const cases = parser.getList(node.right, @intCast(count));

    const saved_breaks = break_count;

    // For each case: compare, jump to body if match
    var case_jumps: [256]u32 = undefined;
    var default_jump: u32 = 0;
    var has_default = false;

    for (cases, 0..) |case_idx, ci| {
        const case_node = parser.getNode(case_idx);
        if (case_node.left != NULL_NODE) {
            // case expr: duplicate discriminant, compile test, compare
            emitOp(.dup);
            compileNode(case_node.left);
            emitOp(.seq); // strict equal
            case_jumps[ci] = emitJump(.jump_if_true);
        } else {
            // default
            has_default = true;
            default_jump = emitJump(.jump);
            case_jumps[ci] = 0;
        }
    }

    // If no match, jump past all cases
    const end_jump = emitJump(.jump);

    // Compile case bodies
    for (cases, 0..) |case_idx, ci| {
        const case_node = parser.getNode(case_idx);
        if (case_node.left != NULL_NODE) {
            patchJump(case_jumps[ci]);
        } else {
            patchJump(default_jump);
        }

        const body_count = case_node.op;
        const stmts = parser.getList(case_node.right, @intCast(body_count));
        for (stmts) |stmt_idx| {
            compileNode(stmt_idx);
        }
    }

    if (!has_default) {
        patchJump(end_jump);
    } else {
        patchJump(end_jump);
    }

    emitOp(.pop); // discard discriminant
    patchBreaks(saved_breaks);
}

fn compileTry(node: Node) void {
    // try { left } catch { right } finally { extra }
    const extras = parser.getList(node.extra, 2);
    const catch_param_idx = if (extras.len > 0) extras[0] else NULL_NODE;
    const finally_idx = if (extras.len > 1) extras[1] else NULL_NODE;

    const try_start = emitJump(.enter_try); // placeholder for catch offset
    // Emit second u16 for finally offset
    emitU16(0);

    compileNode(node.left); // try body
    emitOp(.leave_try);
    const skip_catch = emitJump(.jump); // skip catch on normal flow

    // Catch
    const catch_offset = bc_len;
    patchJumpTo(try_start, catch_offset);

    if (node.right != NULL_NODE) {
        beginScope();
        emitOp(.enter_catch); // pushes exception value
        if (catch_param_idx != NULL_NODE) {
            declareLocal(catch_param_idx);
            emitOp(.set_local);
            emitU16(local_count -| 1);
        } else {
            emitOp(.pop);
        }
        // Compile catch block body directly
        const catch_node = parser.getNode(node.right);
        const clist = parser.getList(catch_node.left, @intCast(catch_node.right));
        for (clist) |stmt| compileNode(stmt);
        endScope();
    }

    patchJump(skip_catch);

    // Finally
    if (finally_idx != NULL_NODE) {
        // Patch finally offset in enter_try
        patchJumpTo(try_start + 2, bc_len);
        emitOp(.enter_finally);
        compileNode(finally_idx);
        emitOp(.leave_finally);
    }
}

fn compileReturn(node: Node) void {
    if (node.left != NULL_NODE) {
        compileNode(node.left);
        emitOp(.ret);
    } else {
        emitOp(.ret_undef);
    }
}

fn compileThrow(node: Node) void {
    compileNode(node.left);
    emitOp(.throw_op);
}

fn compileBreak() void {
    if (break_count < MAX_BREAKS) {
        break_patches[break_count] = emitJump(.jump);
        break_count += 1;
    }
}

fn compileContinue() void {
    if (continue_count < MAX_CONTINUES) {
        continue_patches[continue_count] = emitJump(.jump);
        continue_count += 1;
    }
}

fn compileExprStmt(node: Node) void {
    compileNode(node.left);
    emitOp(.pop); // discard expression result
}

fn compileLabelStmt(node: Node) void {
    // Labels are mostly transparent — just compile the inner statement
    compileNode(node.left);
}

fn compileWithStmt(node: Node) void {
    // with(obj) body — compile obj, body; BotGuard unlikely to use this
    compileNode(node.left);
    emitOp(.pop);
    compileNode(node.right);
}

// ── Expression Compilation ──

fn compileLiteralNum(node: Node) void {
    const tok = lexer.getToken(node.token_idx);
    const text = lexer.tokenText(tok);
    const val = parseFloat(text);

    if (val == 0.0) { emitOp(.load_zero); return; }
    if (val == 1.0) { emitOp(.load_one); return; }

    const idx = addConstant(.{ .num = val });
    emitOp(.load_const);
    emitU16(idx);
}

fn compileLiteralStr(node: Node) void {
    const tok = lexer.getToken(node.token_idx);
    const text = lexer.tokenText(tok);
    // Strip quotes if present
    const content = if (text.len >= 2 and (text[0] == '"' or text[0] == '\'' or text[0] == '`'))
        text[1 .. text.len - 1]
    else
        text;
    const str_idx = values.internString(content);
    const idx = addConstant(.{ .is_string = true, .str_idx = str_idx });
    emitOp(.load_const);
    emitU16(idx);
}

fn compileLiteralBool(node: Node) void {
    if (node.op != 0) {
        emitOp(.load_true);
    } else {
        emitOp(.load_false);
    }
}

fn compileIdentifier(node: Node) void {
    const tok = lexer.getToken(node.token_idx);
    const name = lexer.tokenText(tok);

    // Check locals
    if (resolveLocal(name)) |slot| {
        emitOp(.get_local);
        emitU16(slot);
        return;
    }

    // Check upvalues (would need enclosing function context — simplified for now)
    // Fall through to global
    const idx = addStringConstant(name);
    emitOp(.get_global);
    emitU16(idx);
}

fn compileArray(node: Node) void {
    const list = parser.getList(node.left, @intCast(node.right));
    for (list) |elem_idx| {
        if (elem_idx == NULL_NODE) {
            emitOp(.load_undef); // hole
        } else {
            compileNode(elem_idx);
        }
    }
    emitOp(.make_array);
    emitU16(@intCast(list.len));
}

fn compileObject(node: Node) void {
    const list = parser.getList(node.left, @intCast(node.right));
    for (list) |prop_idx| {
        if (prop_idx == NULL_NODE) continue;
        const prop = parser.getNode(prop_idx);
        if (prop.tag == .spread_expr) {
            compileNode(prop.left);
            emitOp(.spread);
        } else {
            // Key
            compileNode(prop.left);
            // Value
            compileNode(prop.right);
        }
    }
    emitOp(.make_object);
    emitByte(@intCast(@min(list.len, 255)));
}

fn compileFuncExpr(node: Node) void {
    const func_idx = compileFunctionBody(node);
    emitOp(.make_func);
    emitU16(func_idx);
}

fn compileArrow(node: Node) void {
    // Arrow functions are compiled similarly to function expressions
    const func_idx = compileArrowBody(node);
    emitOp(.make_func);
    emitU16(func_idx);
}

fn compileUnary(node: Node) void {
    compileNode(node.left);
    const op_tt: TokenType = @enumFromInt(node.op);
    switch (op_tt) {
        .minus => emitOp(.neg),
        .plus => emitOp(.pos),
        .not => emitOp(.not),
        .bit_not => emitOp(.bit_not),
        .increment => emitOp(.pre_inc),
        .decrement => emitOp(.pre_dec),
        else => {},
    }
}

fn compilePostfix(node: Node) void {
    compileNode(node.left);
    const op_tt: TokenType = @enumFromInt(node.op);
    switch (op_tt) {
        .increment => emitOp(.post_inc),
        .decrement => emitOp(.post_dec),
        else => {},
    }
}

fn compileBinary(node: Node) void {
    compileNode(node.left);
    compileNode(node.right);
    const op_tt: TokenType = @enumFromInt(node.op);
    switch (op_tt) {
        .plus => emitOp(.add),
        .minus => emitOp(.sub),
        .star => emitOp(.mul),
        .slash => emitOp(.div),
        .percent => emitOp(.mod),
        .power => emitOp(.pow),
        .bit_and => emitOp(.bit_and),
        .bit_or => emitOp(.bit_or),
        .bit_xor => emitOp(.bit_xor),
        .lshift => emitOp(.shl),
        .rshift => emitOp(.shr),
        .urshift => emitOp(.ushr),
        .eq => emitOp(.eq),
        .neq => emitOp(.neq),
        .strict_eq => emitOp(.seq),
        .strict_neq => emitOp(.sneq),
        .lt => emitOp(.lt),
        .gt => emitOp(.gt),
        .lte => emitOp(.lte),
        .gte => emitOp(.gte),
        .kw_instanceof => emitOp(.instanceof),
        .kw_in => emitOp(.in_op),
        else => {},
    }
}

fn compileLogical(node: Node) void {
    compileNode(node.left);
    const op_tt: TokenType = @enumFromInt(node.op);

    switch (op_tt) {
        .logical_and => {
            // Short-circuit: if left is falsy, skip right
            const skip = emitJump(.jump_if_false);
            emitOp(.pop);
            compileNode(node.right);
            patchJump(skip);
        },
        .logical_or => {
            const skip = emitJump(.jump_if_true);
            emitOp(.pop);
            compileNode(node.right);
            patchJump(skip);
        },
        .nullish => {
            const skip = emitJump(.jump_nullish);
            emitOp(.pop);
            compileNode(node.right);
            patchJump(skip);
        },
        else => {
            compileNode(node.right);
        },
    }
}

fn compileAssign(node: Node) void {
    const lhs = parser.getNode(node.left);
    const op_tt: TokenType = @enumFromInt(node.op);

    // Simple assignment
    if (op_tt == .assign) {
        compileNode(node.right);
        compileStore(node.left);
        return;
    }

    // Compound assignment (+=, -=, etc.)
    compileNode(node.left); // load current value
    compileNode(node.right);

    // Apply operator
    switch (op_tt) {
        .plus_assign => emitOp(.add),
        .minus_assign => emitOp(.sub),
        .star_assign => emitOp(.mul),
        .slash_assign => emitOp(.div),
        .percent_assign => emitOp(.mod),
        .power_assign => emitOp(.pow),
        .amp_assign => emitOp(.bit_and),
        .pipe_assign => emitOp(.bit_or),
        .caret_assign => emitOp(.bit_xor),
        .lshift_assign => emitOp(.shl),
        .rshift_assign => emitOp(.shr),
        .urshift_assign => emitOp(.ushr),
        else => {},
    }

    _ = lhs;
    compileStore(node.left);
}

fn compileStore(target_idx: NodeIdx) void {
    if (target_idx == NULL_NODE) return;
    const target = parser.getNode(target_idx);

    switch (target.tag) {
        .identifier => {
            const tok = lexer.getToken(target.token_idx);
            const name = lexer.tokenText(tok);
            if (resolveLocal(name)) |slot| {
                emitOp(.set_local);
                emitU16(slot);
            } else {
                const idx = addStringConstant(name);
                emitOp(.set_global);
                emitU16(idx);
            }
        },
        .member_expr => {
            // obj.prop = val → need obj on stack, then set_prop
            compileNode(target.left); // obj
            emitOp(.swap); // [val, obj] → [obj, val]
            const prop_name = nameConstant(target.right);
            emitOp(.set_prop);
            emitU16(prop_name);
        },
        .computed_expr => {
            // obj[key] = val
            compileNode(target.left); // obj
            compileNode(target.right); // key
            // Stack: [val, obj, key] — need to rearrange; simplified:
            emitOp(.set_elem);
        },
        else => {
            // Destructuring or other patterns — simplified
            emitOp(.pop);
        },
    }
}

fn compileCond(node: Node) void {
    compileNode(node.left); // condition
    const false_jump = emitJump(.jump_if_false);
    compileNode(node.right); // consequent
    const end_jump = emitJump(.jump);
    patchJump(false_jump);
    compileNode(node.extra); // alternate
    patchJump(end_jump);
}

fn compileCall(node: Node) void {
    compileNode(node.left); // callee

    const arg_count = node.op;
    const args = parser.getList(node.right, @intCast(arg_count));
    for (args) |arg_idx| {
        compileNode(arg_idx);
    }

    emitOp(.call);
    emitByte(arg_count);
}

fn compileNew(node: Node) void {
    compileNode(node.left); // constructor

    const arg_count = node.op;
    if (arg_count > 0) {
        const args = parser.getList(node.right, @intCast(arg_count));
        for (args) |arg_idx| {
            compileNode(arg_idx);
        }
    }

    emitOp(.new_call);
    emitByte(arg_count);
}

fn compileMember(node: Node) void {
    compileNode(node.left); // object
    const name_const = nameConstant(node.right);
    emitOp(.get_prop);
    emitU16(name_const);
}

fn compileComputed(node: Node) void {
    compileNode(node.left); // object
    compileNode(node.right); // key
    emitOp(.get_elem);
}

fn compileOptional(node: Node) void {
    compileNode(node.left);
    if (node.flags.is_computed) {
        compileNode(node.right);
        emitOp(.get_elem_optional);
    } else {
        const name_const = nameConstant(node.right);
        emitOp(.get_optional);
        emitU16(name_const);
    }
}

fn compileSequence(node: Node) void {
    compileNode(node.left);
    emitOp(.pop);
    compileNode(node.right);
}

fn compileSpread(node: Node) void {
    compileNode(node.left);
    emitOp(.spread);
}

fn compileTypeof(node: Node) void {
    compileNode(node.left);
    emitOp(.typeof_op);
}

fn compileVoid(node: Node) void {
    compileNode(node.left);
    emitOp(.void_op);
}

fn compileDelete(node: Node) void {
    compileNode(node.left);
    emitOp(.delete_op);
}

fn compileYield(node: Node) void {
    if (node.left != NULL_NODE) {
        compileNode(node.left);
    } else {
        emitOp(.load_undef);
    }
    // yield is complex — for BotGuard we stub it
    // The value stays on stack
}

fn compileAwait(node: Node) void {
    compileNode(node.left);
    // await is complex — for BotGuard's sync-only usage, treat as identity
}

// ── Function Compilation ──

fn compileFunctionBody(node: Node) u16 {
    if (n_functions >= MAX_FUNCTIONS) { had_error = true; return 0; }
    const func_id = n_functions;
    n_functions += 1;

    // Save compiler state
    const saved_locals = local_count;
    const saved_depth = scope_depth;
    const saved_bc = bc_len;

    local_count = 0;
    scope_depth = 0;

    // First local is 'this' (or arguments in non-arrow)
    declareLocalDirect("this");

    // Params
    const param_count = node.op;
    const params = parser.getList(node.extra, @intCast(param_count));
    for (params) |p| {
        declareLocal(p);
    }

    // Function body start in bytecode
    const code_start = bc_len;

    // Compile body
    if (node.right != NULL_NODE) {
        const body = parser.getNode(node.right);
        if (body.tag == .block) {
            const stmts = parser.getList(body.left, @intCast(body.right));
            for (stmts) |s| compileNode(s);
        } else {
            // Expression body (arrow)
            compileNode(node.right);
            emitOp(.ret);
        }
    }

    // Implicit return undefined
    emitOp(.ret_undef);

    const code_len = bc_len - code_start;

    // Fill function descriptor
    functions[func_id] = .{
        .code_start = code_start,
        .code_len = code_len,
        .param_count = @intCast(param_count),
        .local_count = local_count,
        .upval_count = 0,
        .name_const = if (node.left != NULL_NODE) nameConstant(node.left) else 0xFFFF,
        .is_arrow = (node.tag == .arrow_expr),
        .is_async = node.flags.is_async,
        .is_generator = node.flags.is_generator,
    };

    // Restore
    local_count = saved_locals;
    scope_depth = saved_depth;
    _ = saved_bc;

    return func_id;
}

fn compileArrowBody(node: Node) u16 {
    if (n_functions >= MAX_FUNCTIONS) { had_error = true; return 0; }
    const func_id = n_functions;
    n_functions += 1;

    const saved_locals = local_count;
    const saved_depth = scope_depth;
    local_count = 0;
    scope_depth = 0;

    // Arrow has no 'this' local (inherits from enclosing)
    const param_count = node.op;

    // Declare params if the left is a sequence-as-params or single ident
    if (node.left != NULL_NODE) {
        const left_node = parser.getNode(node.left);
        if (left_node.tag == .identifier) {
            declareLocal(node.left);
        } else if (left_node.tag == .sequence_expr) {
            // Multi-param: list in left_node.left/right
            const plist = parser.getList(left_node.left, @intCast(left_node.right));
            for (plist) |p| declareLocal(p);
        }
    }

    const code_start = bc_len;

    // Body
    if (node.right != NULL_NODE) {
        const body = parser.getNode(node.right);
        if (body.tag == .block) {
            const stmts = parser.getList(body.left, @intCast(body.right));
            for (stmts) |s| compileNode(s);
            emitOp(.ret_undef);
        } else {
            // Expression body — implicit return
            compileNode(node.right);
            emitOp(.ret);
        }
    } else {
        emitOp(.ret_undef);
    }

    const code_len = bc_len - code_start;

    functions[func_id] = .{
        .code_start = code_start,
        .code_len = code_len,
        .param_count = @intCast(param_count),
        .local_count = local_count,
        .upval_count = 0,
        .name_const = 0xFFFF,
        .is_arrow = true,
        .is_async = node.flags.is_async,
        .is_generator = false,
    };

    local_count = saved_locals;
    scope_depth = saved_depth;
    return func_id;
}

// ── Scope Helpers ──

fn beginScope() void {
    scope_depth += 1;
}

fn endScope() void {
    // Pop locals at current depth
    while (local_count > 0 and locals[local_count - 1].depth >= scope_depth) {
        if (locals[local_count - 1].is_captured) {
            emitOp(.set_upval); // close upvalue
            emitU16(local_count - 1);
        }
        local_count -= 1;
    }
    scope_depth -|= 1;
}

fn declareLocal(name_node_idx: NodeIdx) void {
    if (name_node_idx == NULL_NODE) return;
    const name_node = parser.getNode(name_node_idx);
    if (name_node.tag != .identifier) return;
    const tok = lexer.getToken(name_node.token_idx);

    if (local_count >= MAX_LOCALS) return;
    locals[local_count] = .{
        .name_start = tok.start,
        .name_len = tok.len,
        .depth = scope_depth,
        .is_captured = false,
    };
    local_count += 1;
}

fn declareLocalDirect(name: []const u8) void {
    if (local_count >= MAX_LOCALS) return;
    // For internal names like "this" — we store them with offset 0 (not in source)
    const str_idx = values.internString(name);
    _ = str_idx;
    locals[local_count] = .{
        .name_start = 0,
        .name_len = @intCast(name.len),
        .depth = scope_depth,
        .is_captured = false,
    };
    local_count += 1;
}

fn resolveLocal(name: []const u8) ?u16 {
    if (local_count == 0) return null;
    var i: u16 = local_count;
    while (i > 0) {
        i -= 1;
        const local = locals[i];
        const local_name = lexer.tokenText(.{ .tt = .identifier, .start = local.name_start, .len = local.name_len });
        if (eql(local_name, name)) return i;
    }
    return null;
}

// ── Bytecode Emission ──

fn emitOp(op: Op) void {
    emitByte(@intFromEnum(op));
}

fn emitByte(b: u8) void {
    if (bc_len >= MAX_BYTECODE) { had_error = true; return; }
    bytecode[bc_len] = b;
    bc_len += 1;
}

fn emitU16(val: u16) void {
    emitByte(@intCast(val & 0xFF));
    emitByte(@intCast((val >> 8) & 0xFF));
}

fn emitJump(op: Op) u32 {
    emitOp(op);
    const pos = bc_len;
    emitU16(0xFFFF); // placeholder
    return pos;
}

fn patchJump(offset: u32) void {
    patchJumpTo(offset, bc_len);
}

fn patchJumpTo(offset: u32, target: u32) void {
    if (offset + 1 >= MAX_BYTECODE) return;
    const jump_dist: u16 = @intCast(@min(target, 0xFFFF));
    bytecode[offset] = @intCast(jump_dist & 0xFF);
    bytecode[offset + 1] = @intCast((jump_dist >> 8) & 0xFF);
}

fn emitLoop(target: u32) void {
    emitOp(.loop_back);
    const offset: u16 = @intCast(@min(bc_len - target + 2, 0xFFFF));
    emitU16(offset);
}

fn patchBreaks(saved: u16) void {
    while (break_count > saved) {
        break_count -= 1;
        patchJump(break_patches[break_count]);
    }
}

fn patchContinues(saved: u16, target: u32) void {
    while (continue_count > saved) {
        continue_count -= 1;
        patchJumpTo(continue_patches[continue_count], target);
    }
}

// ── Constant Pool ──

fn addConstant(c: Constant) u16 {
    if (n_constants >= MAX_CONSTANTS) { had_error = true; return 0; }
    constants[n_constants] = c;
    const idx = n_constants;
    n_constants += 1;
    return idx;
}

fn addStringConstant(text: []const u8) u16 {
    const str_idx = values.internString(text);
    return addConstant(.{ .is_string = true, .str_idx = str_idx });
}

fn nameConstant(node_idx: NodeIdx) u16 {
    if (node_idx == NULL_NODE) return 0;
    const node = parser.getNode(node_idx);
    if (node.tag == .identifier) {
        const tok = lexer.getToken(node.token_idx);
        return addStringConstant(lexer.tokenText(tok));
    }
    return 0;
}

// ── Number parsing ──

fn parseFloat(text: []const u8) f64 {
    if (text.len == 0) return 0;
    // Hex
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        var val: f64 = 0;
        for (text[2..]) |c| {
            const digit: f64 = if (c >= '0' and c <= '9') @floatFromInt(c - '0')
                else if (c >= 'a' and c <= 'f') @floatFromInt(c - 'a' + 10)
                else if (c >= 'A' and c <= 'F') @floatFromInt(c - 'A' + 10)
                else break;
            val = val * 16 + digit;
        }
        return val;
    }
    // Decimal
    var val: f64 = 0;
    var sign: f64 = 1;
    var i: usize = 0;
    if (i < text.len and text[i] == '-') { sign = -1; i += 1; }
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        val = val * 10 + @as(f64, @floatFromInt(text[i] - '0'));
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        var frac: f64 = 0.1;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            val += @as(f64, @floatFromInt(text[i] - '0')) * frac;
            frac *= 0.1;
        }
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        var exp_sign: f64 = 1;
        if (i < text.len and text[i] == '-') { exp_sign = -1; i += 1; }
        if (i < text.len and text[i] == '+') i += 1;
        var exp: f64 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            exp = exp * 10 + @as(f64, @floatFromInt(text[i] - '0'));
        }
        val *= pow10(exp_sign * exp);
    }
    return sign * val;
}

fn pow10(exp: f64) f64 {
    // Simple pow10 for exponents
    if (exp == 0) return 1.0;
    var result: f64 = 1.0;
    var e = if (exp < 0) -exp else exp;
    while (e >= 1.0) : (e -= 1.0) {
        result *= 10.0;
    }
    return if (exp < 0) 1.0 / result else result;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}
