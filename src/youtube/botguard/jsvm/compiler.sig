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
    get_global, // u16: name constant index → push global[name] (throws ReferenceError if undeclared)
    get_global_safe, // u16: name constant index → push global[name] or undefined (no throw; for typeof)
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
    call_direct_eval, // u8: argc → like `call` but marks a DIRECT eval(...) so
    // the eval'd code inherits the caller's lexical scope (free vars resolve to
    // the caller frame's locals/upvalues), per JS direct-eval semantics.
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
    enter_try, // u32: catch_offset, u32: finally_offset
    leave_try, // exit try frame
    enter_catch, // push caught exception
    enter_finally, // enter finally block
    leave_finally, // exit finally (re-throw if pending)

    // Iteration / for-in / for-of
    iter_init, // init iterator from TOS
    iter_next, // push next value (or jump u32 if done)
    iter_close, // close iterator

    // Increment / decrement
    pre_inc, // ++x
    pre_dec, // --x
    post_inc, // x++
    post_dec, // x--

    // Misc
    debugger_op,
    set_completion, // pop TOS into VM completion register (eval result value)
    get_completion, // push the VM completion register
    del_prop, // u16 name const: pop obj, delete obj[name], push true
    del_elem, // [obj, key]: delete obj[key], push true
    halt, // end of program
    dup2, // duplicate top TWO stack slots: [a,b] -> [a,b,a,b] (compound elem/prop assign)
    make_regexp, // [pattern, flags] -> fresh intrinsic RegExp literal object
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
    src_start: u32 = 0, // byte offset of this function in the (eval) source
    param_count: u8 = 0,
    local_count: u16 = 0,
    upval_count: u16 = 0,
    name_const: u16 = 0, // constant index for function name (or 0xFFFF)
    is_arrow: bool = false,
    is_async: bool = false,
    is_generator: bool = false,
    // Implicit arguments is reserved after formals but instantiated only when
    // referenced/captured or exposed to direct eval. Arrows inherit it.
    arguments_slot: u16 = 0xFFFF,
    arguments_mapped: bool = true,
    // Persisted local-name table (offset+count into name_tab_pool) so a DIRECT
    // eval can resolve free identifiers against the caller frame's locals by
    // name at runtime (JS direct-eval scope inheritance).
    name_tab_start: u32 = 0,
    name_tab_count: u16 = 0,
    // Exact source text of this function (offset+len into src_text_pool), used by
    // Function.prototype.toString / `""+fn`. BotGuard self-rehydrates functions via
    // `eval("NAME="+fn)`, so toString MUST return the real source, not "[object Function]".
    src_text_off: u32 = 0,
    src_text_len: u32 = 0,
};

// Persisted per-function local name table: interned string idx per local slot.
// slot i (frame-relative) -> string index (0xFFFFFFFF if unnamed/internal).
pub const MAX_NAME_TAB: usize = 262144;
var name_tab_pool: [MAX_NAME_TAB]u32 = [_]u32{0xFFFFFFFF} ** MAX_NAME_TAB;

// Source-text pool: exact source of each compiled function (for toString).
pub const MAX_SRC_TEXT: usize = 4 * 1024 * 1024;
var src_text_pool: [MAX_SRC_TEXT]u8 = undefined;
var src_text_used: u32 = 0;
/// Return the stored source text of a function (empty if none).
pub fn funcSourceText(func_id: u16) []const u8 {
    if (func_id >= n_functions) return "";
    const fd = functions[func_id];
    if (fd.src_text_len == 0) return "";
    const off = fd.src_text_off;
    const end = off + fd.src_text_len;
    if (end > src_text_used) return "";
    return src_text_pool[off..end];
}
var name_tab_used: u32 = 0;
/// Resolve a frame-relative local slot in `func_id` whose name matches the
/// interned string `name_idx`. Returns the slot, or null. Used by the VM's
/// direct-eval caller-scope fallback.
pub fn resolveLocalNameInFunc(func_id: u16, name_idx: u32) ?u16 {
    const fd = functions[func_id];
    var i: u16 = 0;
    while (i < fd.name_tab_count) : (i += 1) {
        if (name_tab_pool[fd.name_tab_start + i] == name_idx) return i;
    }
    return null;
}
/// Interned name (string idx) of a function's frame-relative local slot, or
/// 0xFFFFFFFF if out of range / unnamed. Used by the VM's direct-eval scope
/// exposure to publish caller locals by name.
pub fn funcLocalName(func_id: u16, slot: u16) u32 {
    const fd = functions[func_id];
    if (slot >= fd.name_tab_count) return 0xFFFFFFFF;
    return name_tab_pool[fd.name_tab_start + slot];
}
/// Number of named local slots recorded for a function.
pub fn funcNameTabCount(func_id: u16) u16 {
    return functions[func_id].name_tab_count;
}
/// Interned name of a function's i-th upvalue (0xFFFFFFFF if unknown). Upvalue
/// descriptors now carry the captured variable's name so direct-eval code can
/// resolve free identifiers against an enclosing function's upvalues by name.
pub fn funcUpvalName(func_id: u16, uv_idx: u16) u32 {
    if (func_id >= n_functions) return 0xFFFFFFFF;
    if (uv_idx >= func_upval_desc_count[func_id]) return 0xFFFFFFFF;
    return upval_desc_pool[func_upval_desc_start[func_id] + uv_idx].name;
}

// ── Scope tracking ──

// Flat local slot array shared across ALL live nesting levels at compile time.
// BotGuard's module IIFE alone declares well over 100 locals (observed capture
// index 137), and nested functions stack their locals on top of the same array,
// so 256 was far too small — overflow silently dropped locals (declareLocal
// bails at >= MAX_LOCALS), corrupting slot assignment and closure captures.
const MAX_LOCALS: usize = 8192;
const MAX_SCOPES: usize = 256;
// Per-function upvalue cap. Deeply nested BotGuard closures capture many vars.
// BotGuard's opcode-handler closures capture the entire interpreter state
// (dozens-to-hundreds of free variables threaded through 40+-param enclosing
// functions). A 256 cap made addUpvalue() return null past the limit, so the
// identifier fell back to get_global -> read undefined -> NaN index -> the
// nondeterministic interpreter loop. Counts widened u8 -> u16 to match.
const MAX_UPVALS: usize = 1024;
const MAX_BREAKS: usize = 256;
const MAX_CONTINUES: usize = 256;

const Local = struct {
    name_start: u32 = 0, // offset into source for name
    name_len: u16 = 0,
    // Internal names such as the receiver are interned directly. They do not
    // occupy source bytes and must never read an unrelated source prefix.
    name_idx: u32 = 0xFFFFFFFF,
    depth: u16 = 0, // scope depth
    is_captured: bool = false,
};

fn localName(local: Local) []const u8 {
    if (local.name_idx != 0xFFFFFFFF) return values.getString(local.name_idx);
    return lexer.tokenText(.{ .tt = .identifier, .start = local.name_start, .len = local.name_len });
}

const Upvalue = struct {
    index: u16 = 0, // frame-relative local slot in enclosing fn (or upval index if !is_local)
    is_local: bool = true,
    // Interned name of the captured variable (0xFFFFFFFF if unknown). Needed so
    // eval'd code can resolve a free identifier against an enclosing function's
    // UPVALUES by name (direct-eval lexical scope), not just its locals.
    name: u32 = 0xFFFFFFFF,
    // Direct-eval caller capture kind (only meaningful for the eval BODY's own
    // upvalue list): 0 = normal (captures the immediate enclosing frame per
    // is_local); 1 = caller_local (`index` is a LOCAL SLOT of the eval-caller
    // frame); 2 = caller_upval (`index` is an UPVALUE index of the eval-caller's
    // closure). The VM binds these against the live eval-caller frame/closure.
    eval_kind: u8 = 0,
};

// Direct-eval caller-scope capture kinds (Upvalue.eval_kind).
pub const EVAL_UV_NORMAL: u8 = 0;
pub const EVAL_UV_CALLER_LOCAL: u8 = 1;
pub const EVAL_UV_CALLER_UPVAL: u8 = 2;

// Maximum function nesting depth for the compile-time context stack. Index 0 is
// the top-level / eval body; each nested function pushes a new context.
const MAX_FUNC_NEST: usize = 128;

// ── Compiler State ──

var bytecode: [MAX_BYTECODE]u8 = undefined;
var bc_len: u32 = 0;

// Source-position side table: sparse (bc_offset -> src_offset) entries recorded
// at call/call_method sites, so a runtime failure at a bytecode IP can be
// mapped back to a source location for diagnostics.
const MAX_SRCMAP: usize = 262144;
var srcmap_bc: [MAX_SRCMAP]u32 = undefined;
var srcmap_src: [MAX_SRCMAP]u32 = undefined;
var srcmap_n: usize = 0;
var cur_src_pos: u32 = 0;
fn recordSrcPos(bc_off: u32) void {
    if (srcmap_n < MAX_SRCMAP) { srcmap_bc[srcmap_n] = bc_off; srcmap_src[srcmap_n] = cur_src_pos; srcmap_n += 1; }
}
pub fn dbgSrcmapCount() usize { return srcmap_n; }
/// Map a bytecode offset to the nearest recorded source offset at or before it.
pub fn srcPosForBc(bc_off: u32) u32 {
    var bestbc: u32 = 0;
    var bestsrc: u32 = 0;
    var i: usize = 0;
    while (i < srcmap_n) : (i += 1) {
        if (srcmap_bc[i] <= bc_off and srcmap_bc[i] >= bestbc) { bestbc = srcmap_bc[i]; bestsrc = srcmap_src[i]; }
    }
    return bestsrc;
}

var constants: [MAX_CONSTANTS]Constant = undefined;
var n_constants: u16 = 0;

var functions: [MAX_FUNCTIONS]FuncDesc = undefined;
var n_functions: u16 = 0;

var locals: [MAX_LOCALS]Local = undefined;
var local_count: u16 = 0;
var scope_depth: u16 = 0;

var upvals: [MAX_UPVALS]Upvalue = undefined;
var upval_count: u8 = 0;

// ── Per-function compile context stack (for lexical closures) ──
//
// Locals from all live functions share the flat `locals[]` array. Each nested
// function's locals begin at `func_ctx_local_base[cur_func]`; resolveLocal only
// searches [local_base .. local_count] so a function sees ONLY its own locals.
// Names found in an ENCLOSING function's local range are captured as upvalues.
//
// `cur_func` is the current nesting index (0 = top-level/eval body). It mirrors
// `func_depth` but indexes the context arrays.
var cur_func: u16 = 0;
var func_ctx_local_base: [MAX_FUNC_NEST]u16 = undefined;
var func_upvals: [MAX_FUNC_NEST][MAX_UPVALS]Upvalue = undefined;
var func_upval_count: [MAX_FUNC_NEST]u16 = undefined;
// Per-nesting-level flag: the function at this level contains a DIRECT eval, so
// it must capture its FULL enclosing lexical scope (see compileCall/compileFunctionBody).
var func_has_eval: [MAX_FUNC_NEST]bool = [_]bool{false} ** MAX_FUNC_NEST;
var func_arguments_slot: [MAX_FUNC_NEST]u16 = [_]u16{0xFFFF} ** MAX_FUNC_NEST;
var func_uses_arguments: [MAX_FUNC_NEST]bool = [_]bool{false} ** MAX_FUNC_NEST;
var func_strict: [MAX_FUNC_NEST]bool = [_]bool{false} ** MAX_FUNC_NEST;
// Peak `local_count` reached while compiling each nesting level. Block-scoped
// locals (let/const) get popped by endScope, lowering local_count, but their
// slot indices were already baked into get_local/set_local. The frame MUST
// reserve up to the PEAK slot index, or a nested call's base pointer lands
// inside this frame's local region and the two alias (stack corruption).
var func_local_peak: [MAX_FUNC_NEST]u16 = undefined;
fn bumpLocalPeak() void {
    if (cur_func < MAX_FUNC_NEST and local_count > func_local_peak[cur_func]) {
        func_local_peak[cur_func] = local_count;
    }
}

// Per-function-id upvalue descriptors, stored in a FLAT shared pool (offset +
// count per func) so a large per-function upvalue cap (MAX_UPVALS=8192) does not
// require a [MAX_FUNCTIONS][MAX_UPVALS] matrix (which would be ~134MB). Most
// functions capture few upvalues; a handful capture many, so a flat pool sized
// to the realistic TOTAL is far smaller.
const MAX_UPVAL_DESC_POOL: usize = 262144; // total upvalue descriptors across all funcs
var upval_desc_pool: [MAX_UPVAL_DESC_POOL]Upvalue = undefined;
var n_upval_desc: u32 = 0;
var func_upval_desc_start: [MAX_FUNCTIONS]u32 = undefined; // offset into upval_desc_pool
var func_upval_desc_count: [MAX_FUNCTIONS]u16 = undefined;

// Break/continue patch lists
var break_patches: [MAX_BREAKS]u32 = undefined;
var break_labels: [MAX_BREAKS]u16 = undefined;
var break_count: u16 = 0;
var continue_patches: [MAX_CONTINUES]u32 = undefined;
var continue_labels: [MAX_CONTINUES]u16 = undefined;
var continue_count: u16 = 0;
var loop_start: u32 = 0; // bytecode offset of current loop start
const NO_LABEL: u16 = 0xFFFF;
const LabelScope = struct { name: u32, loop_node: NodeIdx, iter_depth: u16, operand_depth: u16 };
var label_scopes: [128]LabelScope = undefined;
var label_count: u16 = 0;
var label_base: u16 = 0;
var compiling_loop_node: NodeIdx = NULL_NODE;
var control_iter_depth: u16 = 0;
var control_operand_depth: u16 = 0;
var break_iter_depth: u16 = 0;
var break_operand_depth: u16 = 0;
var continue_iter_depth: u16 = 0;
var continue_operand_depth: u16 = 0;

// When compiling an eval body, expression statements store their result into
// the VM completion register (via set_completion) instead of discarding it, so
// eval() can return the value of its last expression.
var eval_mode: bool = false;

// ── Direct-eval caller-scope capture state ──
// When compiling a DIRECT eval body, `eval_caller_active` is set and
// `eval_caller_func` is the func_id of the frame that invoked eval. Free
// identifiers in the eval body (and functions it defines) that are NOT globals
// resolve against the caller's lexical scope: first the caller's own locals (by
// name via its persisted name_tab), then the caller's UPVALUES (by name). Each
// such resolution is recorded as a caller-scope upvalue of the EVAL BODY (a real
// func_id, `eval_body_func`), which the VM binds to the live caller frame/closure
// when it pushes the eval frame. This reproduces JS direct-eval lexical scope
// WITHOUT the lossy publish-to-global hack (exposeAllLiveScopes), so each
// synthesized handler closes over the correct interpreter bindings by reference.
var eval_caller_active: bool = false;
var eval_caller_func: u16 = 0xFFFF;
var eval_body_func: u16 = 0xFFFF;
// The nesting-level-0 upvalue list (func_upvals[0]) is reused to accumulate the
// eval body's caller-scope captures during an eval compile.
pub var dbg_evalcap_n: u32 = 0;
pub var dbg_evalcap_local: u32 = 0;
pub var dbg_evalcap_upval: u32 = 0;
pub var dbg_evalcap_miss: u32 = 0;

// Depth of function nesting. Locals only exist inside functions; at top level
// (func_depth == 0) `var`/for-in vars must be globals because top-level "local
// slots" would alias the operand stack.
var func_depth: u16 = 0;



var had_error: bool = false;

// ── Public API ──

/// Compile the parsed AST into bytecode.
/// Call after parser.parse() has been invoked.
/// Returns bytecode length (0 on failure).
pub fn compile(root: NodeIdx) u32 {
    bc_len = 0;
    srcmap_n = 0;
    cur_src_pos = 0;
    n_constants = 0;
    n_functions = 0;
    n_upval_desc = 0;
    name_tab_used = 0;
    local_count = 0;
    scope_depth = 0;
    upval_count = 0;
    break_count = 0;
    continue_count = 0;
    loop_start = 0;
    func_depth = 0;
    label_count = 0;
    label_base = 0;
    compiling_loop_node = NULL_NODE;
    control_iter_depth = 0;
    control_operand_depth = 0;
    cur_func = 0;
    func_ctx_local_base[0] = 0;
    func_upval_count[0] = 0;
    func_local_peak[0] = 0;
    func_has_eval[0] = false;
    func_arguments_slot[0] = 0xFFFF;
    func_uses_arguments[0] = false;
    func_strict[0] = false;
    had_error = false;

    compileNode(root);
    emitOp(.halt);
    return bc_len;
}

/// Compile an eval'd source's AST by APPENDING to the existing bytecode/const/
/// function pools (does not reset them). Emits a trailing `ret` so a call frame
/// pushed at the returned offset returns cleanly to its caller.
///
/// Returns the bytecode offset where the eval code begins, or 0 on failure
/// (0 is never a valid eval entry because the main program occupies offset 0).
pub fn compileEval(root: NodeIdx, caller_func: u16) u32 {
    // Preserve append position; reset only transient per-compilation state.
    const start = bc_len;
    const saved_locals = local_count;
    const saved_depth = scope_depth;
    const saved_eval = eval_mode;
    const saved_func_depth = func_depth;
    const saved_cur_func = cur_func;
    const saved_eval_caller_active = eval_caller_active;
    const saved_eval_caller_func = eval_caller_func;
    const saved_eval_body_func = eval_body_func;
    local_count = 0;
    scope_depth = 0;
    break_count = 0;
    continue_count = 0;
    loop_start = 0;
    eval_mode = true;
    label_count = 0;
    label_base = 0;
    compiling_loop_node = NULL_NODE;
    control_iter_depth = 0;
    control_operand_depth = 0;
    // eval body is its own top-level context: locals begin at 0. Its "upvalues"
    // are DIRECT-EVAL caller-scope captures (bound to the live caller frame by
    // the VM), accumulated in func_upvals[0] during this compile.
    cur_func = 0;
    func_ctx_local_base[0] = 0;
    func_upval_count[0] = 0;
    func_local_peak[0] = 0;
    func_has_eval[0] = false;
    func_arguments_slot[0] = 0xFFFF;
    func_uses_arguments[0] = false;
    func_strict[0] = false;
    // Enable caller-scope resolution when a real caller func is known and it has
    // a persisted local-name table (i.e. it is a compiled function, not the
    // top-level/sentinel). A DIRECT eval inherits the caller's lexical scope.
    eval_caller_active = (caller_func != 0xFFFF and caller_func != 0xFFFE and caller_func < n_functions);
    eval_caller_func = caller_func;
    if (eval_caller_active) {
        func_depth = 1;
        declareLocalDirect(""); // reserved receiver slot, no source-backed name
        hoistVars(root);
    }
    // Allocate a real func_id for the eval body so its caller-scope upvalue
    // descriptors can be persisted and the VM can build a closure for it.
    if (n_functions < MAX_FUNCTIONS) {
        eval_body_func = @intCast(n_functions);
        n_functions += 1;
    } else {
        eval_body_func = 0xFFFF;
    }

    // eval runs in a frame: reserve local slot 0 for `this` to match the VM's
    // frame convention (this_val / get_local 0).
    emitOp(.load_undef);

    // Expression statements inside store their result into the completion
    // register (eval_mode). Compile the body, then return that register.
    compileNode(root);

    // A nested direct eval can name any caller binding inside its source
    // string. Keep the complete inherited environment even when this body's
    // bytecode never reads the binding itself.
    if (func_has_eval[0]) captureAllEnclosingLocals();

    emitOp(.get_completion);
    emitOp(.ret);

    // Persist the eval body's caller-scope upvalue descriptors under its func_id
    // so the VM can bind them to the live caller frame when pushing the frame.
    if (eval_body_func != 0xFFFF) {
        const n_uv = func_upval_count[0];
        func_upval_desc_count[eval_body_func] = n_uv;
        func_upval_desc_start[eval_body_func] = n_upval_desc;
        var ui: u16 = 0;
        while (ui < n_uv and n_upval_desc < MAX_UPVAL_DESC_POOL) : (ui += 1) {
            upval_desc_pool[n_upval_desc] = func_upvals[0][ui];
            n_upval_desc += 1;
        }
        // Persist local names as for ordinary functions. An eval body is a
        // lexical caller when it invokes another direct eval.
        const nt_start = name_tab_used;
        var nt_count: u16 = 0;
        var si: u16 = 0;
        while (si < local_count and name_tab_used < MAX_NAME_TAB) : (si += 1) {
            const ln = locals[si];
            name_tab_pool[name_tab_used] = if (ln.name_len == 0) 0xFFFFFFFF else values.internString(localName(ln));
            name_tab_used += 1;
            nt_count += 1;
        }
        functions[eval_body_func] = .{
            .code_start = start,
            .code_len = bc_len - start,
            .src_start = 0,
            .param_count = 0,
            .local_count = func_local_peak[0],
            .upval_count = n_uv,
            .name_const = 0xFFFF,
            .is_arrow = false,
            .is_async = false,
            .is_generator = false,
            .name_tab_start = nt_start,
            .name_tab_count = nt_count,
        };
    }

    const result_body_func = eval_body_func;
    dbg_last_eval_body_func = result_body_func;

    local_count = saved_locals;
    scope_depth = saved_depth;
    eval_mode = saved_eval;
    func_depth = saved_func_depth;
    cur_func = saved_cur_func;
    eval_caller_active = saved_eval_caller_active;
    eval_caller_func = saved_eval_caller_func;
    eval_body_func = saved_eval_body_func;

    if (had_error) return 0;
    return start;
}

/// func_id assigned to the most recently compiled eval body (0xFFFF if none /
/// failed). The VM uses this to create the eval frame's closure so free
/// identifiers resolve to the caller's lexical scope by reference.
pub var dbg_last_eval_body_func: u16 = 0xFFFF;
pub fn lastEvalBodyFunc() u16 { return dbg_last_eval_body_func; }

/// Get the current bytecode length (append cursor). Used by the VM to know
/// where freshly compiled eval code was placed.
pub fn bytecodeLen() u32 {
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

/// Debug: get the string of a string-constant by index (empty if not a string).
pub fn constStr(idx: u16) []const u8 {
    if (idx >= n_constants) return "";
    const c = constants[idx];
    if (!c.is_string) return "";
    return values.getString(c.str_idx);
}

/// Get a function descriptor.
pub fn dbgFunctionCount() u16 { return n_functions; }
pub fn getFunction(idx: u16) FuncDesc {
    if (idx >= n_functions) return .{};
    return functions[idx];
}

/// A closure upvalue descriptor exposed to the VM. `is_local` means "capture
/// the enclosing frame's local at `index`"; otherwise "copy the enclosing
/// closure's upvalue at `index`".
pub const UpvalDesc = struct {
    index: u16 = 0,
    is_local: bool = true,
    // Direct-eval caller capture kind (see compiler.Upvalue.eval_kind).
    // EVAL_UV_NORMAL for ordinary lexical upvalues; EVAL_UV_CALLER_LOCAL /
    // EVAL_UV_CALLER_UPVAL for the eval BODY's caller-scope captures.
    eval_kind: u8 = 0,
};

/// Number of upvalues a function (by func_id) captures.
pub fn upvalCount(func_id: u16) u16 {
    if (func_id >= n_functions) return 0;
    return func_upval_desc_count[func_id];
}

/// Get the i-th upvalue descriptor for a function (by func_id).
pub fn upvalDescAt(func_id: u16, i: u16) UpvalDesc {
    if (func_id >= n_functions) return .{};
    if (i >= func_upval_desc_count[func_id]) return .{};
    const uv = upval_desc_pool[func_upval_desc_start[func_id] + i];
    return .{ .index = uv.index, .is_local = uv.is_local, .eval_kind = uv.eval_kind };
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
    cur_src_pos = lexer.getToken(node.token_idx).start;

    switch (node.tag) {
        .program => compileProgram(node),
        .block => compileBlock(node),
        .var_decl => compileVarDecl(node),
        .func_decl => compileFuncDecl(node),
        .class_decl => compileClassDecl(node),
        .if_stmt => compileIf(node),
        .for_stmt, .for_in_stmt, .for_of_stmt, .while_stmt, .do_while_stmt => compileIteration(idx, node),
        .switch_stmt => compileSwitchScope(node),
        .try_stmt => compileTry(node),
        .return_stmt => compileReturn(node),
        .throw_stmt => compileThrow(node),
        .break_stmt => compileBreak(node),
        .continue_stmt => compileContinue(node),
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
        .literal_regex => compileLiteralRegex(node),
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
    const is_block_scoped = node.flags.is_let or node.flags.is_const;

    if (func_depth > 0) {
        // Inside a function: HOIST all declared names first (JS `var` semantics),
        // so a name is visible to sibling declarators' initializer bodies even
        // when it is assigned later. BotGuard's whole function table is one big
        // `var Me=..., ..., Ne=...` where earlier functions (e.g. Me) close over
        // later-declared vars (e.g. Ne); without hoisting, Me would compile Ne as
        // an undefined global. `let`/`const` remain block-scoped (declared as the
        // init runs, no forward visibility) to preserve TDZ-ish ordering.
        if (!is_block_scoped) {
            var h: usize = 0;
            while (h + 1 < list.len) : (h += 2) {
                // Skip if already declared in this function scope (avoid dupes).
                const nm_node = list[h];
                if (nm_node == NULL_NODE) continue;
                const nn = parser.getNode(nm_node);
                if (nn.tag != .identifier) continue;
                const nt = lexer.getToken(nn.token_idx);
                if (resolveLocal(lexer.tokenText(nt)) == null) {
                    declareLocalFuncScoped(nm_node);
                }
            }
        }
        var i: usize = 0;
        while (i + 1 < list.len) : (i += 2) {
            const name_idx = list[i];
            const init_idx = list[i + 1];
            if (init_idx == NULL_NODE) continue; // hoisted; no assignment
            compileNode(init_idx);
            // Resolve the (already-hoisted for var) slot; let/const declare now.
            var slot: u16 = 0;
            if (is_block_scoped) {
                declareLocal(name_idx);
                slot = lastLocalSlot();
            } else {
                const nn = parser.getNode(name_idx);
                const nt = lexer.getToken(nn.token_idx);
                slot = resolveLocal(lexer.tokenText(nt)) orelse blk: {
                    declareLocalFuncScoped(name_idx);
                    break :blk lastLocalSlot();
                };
            }
            emitOp(.set_local);
            emitU16(slot);
            emitOp(.pop); // set_local peeks; discard the value.
        }
    } else {
        var i: usize = 0;
        while (i + 1 < list.len) : (i += 2) {
            const name_idx = list[i];
            const init_idx = list[i + 1];
            if (init_idx != NULL_NODE) {
                compileNode(init_idx);
            } else {
                emitOp(.load_undef);
            }
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

    if (func_depth > 0) {
        // hoistVars has already reserved this declaration's binding. Creating
        // a second slot leaves the named environment's first slot undefined,
        // so direct eval finds a different value from an ordinary local read.
        const nn = parser.getNode(node.left);
        const nt = lexer.getToken(nn.token_idx);
        const slot = resolveLocal(lexer.tokenText(nt)) orelse blk: {
            declareLocalFuncScoped(node.left);
            break :blk lastLocalSlot();
        };
        emitOp(.set_local);
        emitU16(slot);
        emitOp(.pop);
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
        if (func_depth > 0) {
            declareLocal(node.left);
            emitOp(.set_local);
            emitU16(lastLocalSlot());
            emitOp(.pop);
        } else {
            const name_const = nameConstant(node.left);
            emitOp(.def_global);
            emitU16(name_const);
        }
    }
}

fn clearStatementCompletion() void {
    if (eval_mode) { emitOp(.load_undef); emitOp(.set_completion); }
}

fn compileIf(node: Node) void {
    clearStatementCompletion();
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
    clearStatementCompletion();
    beginScope();

    // Init. A var-decl init manages its own stack (compileVarDecl pops each
    // initializer). A bare EXPRESSION init (e.g. `for(M=x, q=[]; ...)`) is an
    // expression whose result is left on the operand stack, so it must be
    // discarded here — otherwise every such for-loop leaks one stack slot,
    // corrupting all subsequent operand-stack-relative accesses (BotGuard uses
    // `for(expr-init; ...)` pervasively).
    if (node.left != NULL_NODE) {
        const init_node = parser.getNode(node.left);
        compileNode(node.left);
        if (init_node.tag != .var_decl) {
            emitOp(.pop);
        }
    }

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
    clearStatementCompletion();
    beginScope();
    compileNode(node.right); // the object to iterate
    emitOp(.iter_init);

    const saved_loop = loop_start;
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    loop_start = bc_len;

    const exit_jump = emitJump(.iter_next);

    // Assign the current key (on TOS) to the loop variable, then pop it.
    if (node.left != NULL_NODE) {
        const lhs_node = parser.getNode(node.left);
        if (lhs_node.tag == .var_decl) {
            const vlist = parser.getList(lhs_node.left, @intCast(lhs_node.right));
            if (vlist.len > 0) {
                // for-in var: bind as a global (scope_depth heuristics aside,
                // BotGuard's for-in vars are function-scoped; store to the
                // declared name via set_global when at top-level function).
                storeForInVar(vlist[0]);
            } else {
                emitOp(.pop);
            }
        } else {
            // Assignment target expression (e.g. plain identifier).
            compileStoreKey(node.left);
        }
    } else {
        emitOp(.pop);
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

/// Store the for-in key (currently on TOS) into a declared loop variable node,
/// then pop it. Uses local slot if in a function scope, else a global.
fn storeForInVar(name_node: NodeIdx) void {
    if (name_node == NULL_NODE) { emitOp(.pop); return; }
    const nn = parser.getNode(name_node);
    if (nn.tag != .identifier) { emitOp(.pop); return; }
    const tok = lexer.getToken(nn.token_idx);
    const name = lexer.tokenText(tok);
    if (resolveLocal(name)) |slot| {
        emitOp(.set_local);
        emitU16(slot);
    } else if (resolveUpvalue(name, cur_func)) |uv| {
        emitOp(.set_upval);
        emitU16(uv);
    } else if (func_depth > 0) {
        declareLocal(name_node);
        emitOp(.set_local);
        emitU16(lastLocalSlot());
    } else {
        const idx = addStringConstant(name);
        emitOp(.set_global);
        emitU16(idx);
    }
    emitOp(.pop);
}

/// Store the for-in key (on TOS) into an existing assignment target, then pop.
fn compileStoreKey(target_idx: NodeIdx) void {
    compileStore(target_idx);
    emitOp(.pop);
}

fn compileForOf(node: Node) void {
    // Same structure as for-in but with different iteration semantics
    compileForIn(node); // reuse — VM differentiates via iter_init behavior
}

fn compileWhile(node: Node) void {
    clearStatementCompletion();
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
    clearStatementCompletion();
    const saved_loop = loop_start;
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    loop_start = bc_len;

    compileNode(node.right); // body

    const continue_target = bc_len;
    compileNode(node.left); // condition
    // Jump back if true
    const cond_jump = emitJump(.jump_if_true);
    // Patch to loop start (operand is the 4-byte target just emitted).
    patchJumpTo(cond_jump, loop_start);

    patchBreaks(saved_breaks);
    patchContinues(saved_continues, continue_target);
    loop_start = saved_loop;
}

fn compileSwitch(node: Node) void {
    clearStatementCompletion();
    compileNode(node.left); // discriminant

    const count = node.op;
    const cases = parser.getList(node.right, @intCast(count));

    const saved_breaks = break_count;

    // For each case: compare, jump to body if match
    var case_jumps: [256]u32 = undefined;
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
            case_jumps[ci] = 0;
        }
    }

    // Choose default only after testing every case expression. Its position
    // controls fallthrough order, but must not bypass later comparisons.
    const end_jump = emitJump(.jump);

    // Compile case bodies
    for (cases, 0..) |case_idx, ci| {
        const case_node = parser.getNode(case_idx);
        if (case_node.left != NULL_NODE) {
            patchJump(case_jumps[ci]);
        } else {
            patchJump(end_jump);
        }

        const body_count = case_node.op;
        const stmts = parser.getList(case_node.right, @intCast(body_count));
        for (stmts) |stmt_idx| {
            compileNode(stmt_idx);
        }
    }

    if (!has_default) {
        patchJump(end_jump);
    }

    emitOp(.pop); // discard discriminant
    patchBreaks(saved_breaks);
}

fn compileTry(node: Node) void {
    clearStatementCompletion();
    // try { left } catch (catch_param) { right } finally { extra }
    const extras = parser.getList(node.extra, 2);
    const catch_param_idx = if (extras.len > 0) extras[0] else NULL_NODE;
    const finally_idx = if (extras.len > 1) extras[1] else NULL_NODE;
    const has_catch = node.right != NULL_NODE;
    const has_finally = finally_idx != NULL_NODE;

    // `try{B}catch{C}finally{F}` is compiled as the nested form
    //   try { try{B}catch{C} } finally{F}
    // so that an exception (or re-throw) INSIDE the catch block still runs the
    // finally on the way out. The outer frame is finally-only (catch_ip=0); the
    // inner frame carries the catch. When there's no finally, only the inner
    // (catch) layer is emitted; when there's no catch, only the finally layer.

    // ── Outer finally layer (if a finally exists) ──
    var outer_try: u32 = 0;
    if (has_finally) {
        outer_try = emitJump(.enter_try); // catch offset (patched to 0 = finally-only)
        emitU32(0); // finally offset (patched below)
        patchJumpTo(outer_try, 0);
    }

    // ── Inner try body + catch ──
    const inner_try = emitJump(.enter_try);
    emitU32(0); // no finally on the inner frame
    patchJumpTo(inner_try, 0); // default catch_ip=0 until patched

    compileNode(node.left); // try body
    emitOp(.leave_try);
    const skip_catch = emitJump(.jump); // normal flow skips the catch

    if (has_catch) {
        patchJumpTo(inner_try, bc_len); // inner catch_ip
        clearStatementCompletion();
        beginScope();
        emitOp(.enter_catch); // pushes exception value
        if (catch_param_idx != NULL_NODE) {
            declareLocal(catch_param_idx);
            emitOp(.set_local);
            emitU16(lastLocalSlot());
        } else {
            emitOp(.pop);
        }
        const catch_node = parser.getNode(node.right);
        const clist = parser.getList(catch_node.left, @intCast(catch_node.right));
        for (clist) |stmt| compileNode(stmt);
        endScope();
    }
    patchJump(skip_catch);

    // ── Finally block (runs on normal completion AND on unwind) ──
    if (has_finally) {
        // Close the inner frame is implicit (leave_try above / catch consumed).
        emitOp(.leave_try); // pop the OUTER finally frame before running finally
        patchJumpTo(outer_try + 4, bc_len); // outer finally offset
        if (eval_mode) emitOp(.get_completion); // preserve the try/catch value
        clearStatementCompletion(); // finally has its own statement value
        emitOp(.enter_finally);
        compileNode(finally_idx);
        if (eval_mode) emitOp(.set_completion); // a normal finally preserves it
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

fn jumpLabel(node: Node, is_continue: bool) u16 {
    const tok = lexer.getToken(node.token_idx);
    if (tok.tt != .identifier) return NO_LABEL;
    const name = values.internString(lexer.tokenText(tok));
    var i = label_count;
    while (i > label_base) {
        i -= 1;
        if (label_scopes[i].name != name) continue;
        if (is_continue and label_scopes[i].loop_node == NULL_NODE) had_error = true;
        return i;
    }
    had_error = true;
    return NO_LABEL;
}

fn compileBreak(node: Node) void {
    const label = jumpLabel(node, false);
    if (had_error) return;
    emitJumpCleanup(if (label == NO_LABEL) break_iter_depth else label_scopes[label].iter_depth, if (label == NO_LABEL) break_operand_depth else label_scopes[label].operand_depth);
    if (break_count < MAX_BREAKS) {
        break_patches[break_count] = emitJump(.jump);
        break_labels[break_count] = label;
        break_count += 1;
    } else had_error = true;
}

fn compileContinue(node: Node) void {
    const label = jumpLabel(node, true);
    if (had_error) return;
    var keep_iter = continue_iter_depth;
    if (label != NO_LABEL) {
        const scope = label_scopes[label];
        const tag = parser.getNode(scope.loop_node).tag;
        keep_iter = scope.iter_depth + @as(u16, if (tag == .for_in_stmt or tag == .for_of_stmt) 1 else 0);
    }
    emitJumpCleanup(keep_iter, if (label == NO_LABEL) continue_operand_depth else label_scopes[label].operand_depth);
    if (continue_count < MAX_CONTINUES) {
        continue_patches[continue_count] = emitJump(.jump);
        continue_labels[continue_count] = label;
        continue_count += 1;
    } else had_error = true;
}

fn compileExprStmt(node: Node) void {
    compileNode(node.left);
    if (eval_mode) {
        // In eval, the value of the last-evaluated expression statement is the
        // completion value. Stash it into the VM completion register (also pops).
        emitOp(.set_completion);
    } else {
        emitOp(.pop); // discard expression result
    }
}

fn compileLabelStmt(node: Node) void {
    // Named breaks remain pending through nested loops/switches until their
    // actual label exits. Chained labels share the same iteration target.
    if (label_count >= label_scopes.len) { had_error = true; return; }
    var body_idx = node.left;
    while (parser.getNode(body_idx).tag == .label_stmt) body_idx = parser.getNode(body_idx).left;
    const body_tag = parser.getNode(body_idx).tag;
    const iteration = body_tag == .for_stmt or body_tag == .for_in_stmt or body_tag == .for_of_stmt or body_tag == .while_stmt or body_tag == .do_while_stmt;
    const scope = label_count;
    label_scopes[scope] = .{ .name = values.internString(lexer.tokenText(lexer.getToken(node.token_idx))), .loop_node = if (iteration) body_idx else NULL_NODE, .iter_depth = control_iter_depth, .operand_depth = control_operand_depth };
    label_count += 1;
    const saved_breaks = break_count;
    compileNode(node.left);
    patchLabelBreaks(saved_breaks, scope);
    label_count -= 1;
}

fn compileIteration(idx: NodeIdx, node: Node) void {
    const saved = compiling_loop_node;
    const saved_break_iter = break_iter_depth;
    const saved_break_operand = break_operand_depth;
    const saved_continue_iter = continue_iter_depth;
    const saved_continue_operand = continue_operand_depth;
    compiling_loop_node = idx;
    break_iter_depth = control_iter_depth;
    break_operand_depth = control_operand_depth;
    const uses_iter = node.tag == .for_in_stmt or node.tag == .for_of_stmt;
    if (uses_iter) control_iter_depth += 1;
    continue_iter_depth = control_iter_depth;
    continue_operand_depth = control_operand_depth;
    switch (node.tag) {
        .for_stmt => compileFor(node),
        .for_in_stmt => compileForIn(node),
        .for_of_stmt => compileForOf(node),
        .while_stmt => compileWhile(node),
        .do_while_stmt => compileDoWhile(node),
        else => {},
    }
    if (uses_iter) control_iter_depth -= 1;
    compiling_loop_node = saved;
    break_iter_depth = saved_break_iter;
    break_operand_depth = saved_break_operand;
    continue_iter_depth = saved_continue_iter;
    continue_operand_depth = saved_continue_operand;
}

fn compileSwitchScope(node: Node) void {
    const saved_break_iter = break_iter_depth;
    const saved_break_operand = break_operand_depth;
    break_iter_depth = control_iter_depth;
    break_operand_depth = control_operand_depth;
    control_operand_depth += 1; // discriminant retained during case bodies
    compileSwitch(node);
    control_operand_depth -= 1;
    break_iter_depth = saved_break_iter;
    break_operand_depth = saved_break_operand;
}

fn emitJumpCleanup(keep_iter: u16, keep_operand: u16) void {
    var i = keep_iter;
    while (i < control_iter_depth) : (i += 1) emitOp(.iter_close);
    i = keep_operand;
    while (i < control_operand_depth) : (i += 1) emitOp(.pop);
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

// Scratch for decoding string-literal escape sequences.
var unescape_buf: [512 * 1024]u8 = undefined;

fn compileLiteralRegex(node: Node) void {
    const text = lexer.tokenText(lexer.getToken(node.token_idx));
    var end = text.len;
    while (end > 1 and text[end - 1] != '/') end -= 1;
    if (end <= 1) { emitOp(.load_undef); return; }
    // Regex escapes belong to the pattern parser, not string unescaping.
    emitOp(.load_const); emitU16(addStringConstant(text[1 .. end - 1]));
    emitOp(.load_const); emitU16(addStringConstant(text[end..]));
    emitOp(.make_regexp);
}

fn compileLiteralStr(node: Node) void {
    const tok = lexer.getToken(node.token_idx);
    const text = lexer.tokenText(tok);
    // Strip quotes if present
    const content = if (text.len >= 2 and (text[0] == '"' or text[0] == '\'' or text[0] == '`'))
        text[1 .. text.len - 1]
    else
        text;
    const decoded = unescapeString(content);
    const str_idx = values.internString(decoded);
    const idx = addConstant(.{ .is_string = true, .str_idx = str_idx });
    emitOp(.load_const);
    emitU16(idx);
}

/// Decode JS string escape sequences into unescape_buf; returns the decoded
/// slice. Handles \n \t \r \\ \" \' \` \0 \b \f \v \xHH \uHHHH (BMP, UTF-8).
fn unescapeString(s: []const u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len and o < unescape_buf.len) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            unescape_buf[o] = c; o += 1; i += 1;
            continue;
        }
        // Escape sequence.
        const e = s[i + 1];
        i += 2;
        switch (e) {
            'n' => { unescape_buf[o] = '\n'; o += 1; },
            't' => { unescape_buf[o] = '\t'; o += 1; },
            'r' => { unescape_buf[o] = '\r'; o += 1; },
            'b' => { unescape_buf[o] = 8; o += 1; },
            'f' => { unescape_buf[o] = 12; o += 1; },
            'v' => { unescape_buf[o] = 11; o += 1; },
            '0' => { unescape_buf[o] = 0; o += 1; },
            '\\' => { unescape_buf[o] = '\\'; o += 1; },
            '"' => { unescape_buf[o] = '"'; o += 1; },
            '\'' => { unescape_buf[o] = '\''; o += 1; },
            '`' => { unescape_buf[o] = '`'; o += 1; },
            'x' => {
                // \xHH
                if (i + 1 < s.len) {
                    const hi = hexVal(s[i]);
                    const lo = hexVal(s[i + 1]);
                    unescape_buf[o] = (hi << 4) | lo; o += 1;
                    i += 2;
                }
            },
            'u' => {
                // \uHHHH (BMP) -> UTF-8. (\u{...} form not handled.)
                if (i + 3 < s.len and s[i] != '{') {
                    const cp: u32 = (@as(u32, hexVal(s[i])) << 12) |
                        (@as(u32, hexVal(s[i + 1])) << 8) |
                        (@as(u32, hexVal(s[i + 2])) << 4) |
                        @as(u32, hexVal(s[i + 3]));
                    i += 4;
                    o += encodeUtf8(cp, unescape_buf[o..]);
                } else {
                    unescape_buf[o] = 'u'; o += 1;
                }
            },
            else => { unescape_buf[o] = e; o += 1; },
        }
    }
    return unescape_buf[0..o];
}

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

/// Encode a Unicode code point as UTF-8 into out; returns bytes written.
fn encodeUtf8(cp: u32, out: []u8) usize {
    if (cp < 0x80) {
        if (out.len < 1) return 0;
        out[0] = @intCast(cp); return 1;
    } else if (cp < 0x800) {
        if (out.len < 2) return 0;
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else {
        if (out.len < 3) return 0;
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
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

    // Check upvalues: a name bound in an ENCLOSING function's locals is captured
    // as an upvalue of the current function (lexical closure).
    if (resolveUpvalue(name, cur_func)) |uv| {
        emitOp(.get_upval);
        emitU16(uv);
        return;
    }

    // Fall through to global.
    // Debug: for a watched 1-char name that falls through to global, capture the
    // EXACT source byte offset of THIS reference (token start) plus cur_func, so
    // we can inspect the reference's real lexical context (src_start is bogus).
    if (name.len == 1 and name[0] == dbg_wtrack_char and dbg_wref_count < 8) {
        dbg_wref_src[dbg_wref_count] = tok.start;
        dbg_wref_curfunc[dbg_wref_count] = cur_func;
        dbg_wref_count += 1;
    }
    // Targeted: capture reads of K/U/f that fall through to GLOBAL, with cur_func
    // and the enclosing scope bases — to diagnose the op-64 handler's failed
    // upvalue resolution.
    if (dbg_kuf_on and name.len == 1 and (name[0] == 'K' or name[0] == 'U' or name[0] == 'f') and dbg_kuf_n < 32) {
        dbg_kuf_name[dbg_kuf_n] = name[0];
        dbg_kuf_curfunc[dbg_kuf_n] = cur_func;
        dbg_kuf_encbase[dbg_kuf_n] = if (cur_func > 0) func_ctx_local_base[cur_func - 1] else 0;
        dbg_kuf_childbase[dbg_kuf_n] = func_ctx_local_base[cur_func];
        dbg_kuf_localcount[dbg_kuf_n] = local_count;
        dbg_kuf_n += 1;
    }
    const idx = addStringConstant(name);
    emitOp(.get_global);
    emitU16(idx);
}
pub var dbg_cfb_want: u16 = 0xFFFF;
pub var dbg_cfb_seen: bool = false;
pub var dbg_cfb_curfunc: u16 = 0;
pub var dbg_cfb_localcount: u16 = 0;
pub var dbg_cfb_haderr: bool = false;
pub fn dbgCfb() [4]u32 { return .{ if (dbg_cfb_seen) 1 else 0, dbg_cfb_curfunc, dbg_cfb_localcount, if (dbg_cfb_haderr) 1 else 0 }; }
pub var dbg_cfb_hist: [16]u32 = [_]u32{0} ** 16;
pub fn dbgCfbHist(i: usize) u32 { return dbg_cfb_hist[i % 16]; }
pub var dbg_kuf_on: bool = false;
pub var dbg_kuf_n: u32 = 0;
pub var dbg_kuf_name: [32]u8 = [_]u8{0} ** 32;
pub var dbg_kuf_curfunc: [32]u16 = [_]u16{0} ** 32;
pub var dbg_kuf_encbase: [32]u16 = [_]u16{0} ** 32;
pub var dbg_kuf_childbase: [32]u16 = [_]u16{0} ** 32;
pub var dbg_kuf_localcount: [32]u16 = [_]u16{0} ** 32;
pub fn dbgKufN() u32 { return dbg_kuf_n; }
pub fn dbgKufName(i: usize) u8 { return dbg_kuf_name[i % 32]; }
pub fn dbgKufCurfunc(i: usize) u16 { return dbg_kuf_curfunc[i % 32]; }
pub fn dbgKufEncbase(i: usize) u16 { return dbg_kuf_encbase[i % 32]; }
pub fn dbgKufChildbase(i: usize) u16 { return dbg_kuf_childbase[i % 32]; }
pub fn dbgKufLocalcount(i: usize) u16 { return dbg_kuf_localcount[i % 32]; }
pub var dbg_wref_count: u32 = 0;
pub var dbg_wref_src: [8]u32 = [_]u32{0} ** 8;
pub var dbg_wref_curfunc: [8]u16 = [_]u16{0} ** 8;
pub var dbg_eval_wtrack_active: bool = false;
pub var dbg_hoist_max_listlen: u32 = 0;
pub var dbg_hoist_saw_w: u32 = 0;

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
    // Elisions reserve array length without creating indexed properties.
    // The literal's undefined placeholders have now been consumed; discard
    // only its elided indexes while retaining the resulting array on stack.
    for (list, 0..) |elem_idx, index| {
        if (elem_idx != NULL_NODE) continue;
        emitOp(.dup);
        emitOp(.load_const); emitU16(addConstant(.{ .num = @floatFromInt(index) }));
        emitOp(.del_elem);
        emitOp(.pop);
    }
}

fn compileObject(node: Node) void {
    const list = parser.getList(node.left, @intCast(node.right));
    var real_count: usize = 0;
    for (list) |prop_idx| {
        if (prop_idx == NULL_NODE) continue;
        const prop = parser.getNode(prop_idx);
        if (prop.tag == .spread_expr) {
            compileNode(prop.left);
            emitOp(.spread);
            real_count += 1;
            continue;
        }
        // Key: push the property NAME (a string), not the value of an
        // identifier variable. Computed keys ([expr]) are evaluated.
        const key = parser.getNode(prop.left);
        if (prop.flags.is_computed) {
            compileNode(prop.left); // evaluate computed key expression
        } else if (key.tag == .identifier or key.tag == .literal_str) {
            const tok = lexer.getToken(key.token_idx);
            var name = lexer.tokenText(tok);
            // Strip quotes for string-literal keys.
            if (key.tag == .literal_str and name.len >= 2 and (name[0] == '"' or name[0] == '\'')) {
                name = name[1 .. name.len - 1];
            }
            const kidx = addStringConstant(name);
            emitOp(.load_const);
            emitU16(kidx);
        } else if (key.tag == .literal_num) {
            // Numeric key -> use its text as the property name string.
            const tok = lexer.getToken(key.token_idx);
            const kidx = addStringConstant(lexer.tokenText(tok));
            emitOp(.load_const);
            emitU16(kidx);
        } else {
            compileNode(prop.left);
        }
        // Value
        compileNode(prop.right);
        real_count += 1;
    }
    emitOp(.make_object);
    emitByte(@intCast(@min(real_count, 255)));
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
    const op_tt: TokenType = @enumFromInt(node.op);
    switch (op_tt) {
        .minus => { compileNode(node.left); emitOp(.neg); },
        .plus => { compileNode(node.left); emitOp(.pos); },
        .not => { compileNode(node.left); emitOp(.not); },
        .bit_not => { compileNode(node.left); emitOp(.bit_not); },
        // Prefix ++x / --x : read, +/-1, store back; result is the NEW value.
        .increment => compilePrefixIncDec(node.left, true),
        .decrement => compilePrefixIncDec(node.left, false),
        else => { compileNode(node.left); },
    }
}

fn compilePostfix(node: Node) void {
    const op_tt: TokenType = @enumFromInt(node.op);
    switch (op_tt) {
        .increment => compilePostfixIncDec(node.left, true),
        .decrement => compilePostfixIncDec(node.left, false),
        else => { compileNode(node.left); },
    }
}

/// Prefix ++x / --x : x = x +/- 1; result is the new value.
fn compilePrefixIncDec(target: NodeIdx, is_inc: bool) void {
    compileNode(target); // old value
    emitOp(.load_one);
    emitOp(if (is_inc) .add else .sub); // new value on TOS
    compileStore(target); // stores (peeks), leaves new value
}

/// Postfix x++ / x-- : result is the old value; x = x +/- 1.
fn compilePostfixIncDec(target: NodeIdx, is_inc: bool) void {
    compileNode(target); // old value
    emitOp(.pos); // coerce to number so the result is numeric
    emitOp(.dup); // [old, old]
    emitOp(.load_one);
    emitOp(if (is_inc) .add else .sub); // [old, new]
    compileStore(target); // stores new (peeks), leaves new -> [old, new]
    emitOp(.pop); // -> [old]
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

    // Short-circuit operators must leave the DECIDING value as the result when
    // they short-circuit. Our jump_if_false/true POP the tested value, so we
    // `dup` first: the jump consumes the dup, the original stays on short-
    // circuit; on the non-short path we pop it and evaluate the right operand.
    switch (op_tt) {
        .logical_and => {
            // a && b : if a falsy -> result a; else -> result b
            emitOp(.dup);
            const skip = emitJump(.jump_if_false); // pops the dup; if falsy keep original
            emitOp(.pop); // truthy: discard a
            compileNode(node.right);
            patchJump(skip);
        },
        .logical_or => {
            // a || b : if a truthy -> result a; else -> result b
            emitOp(.dup);
            const skip = emitJump(.jump_if_true);
            emitOp(.pop);
            compileNode(node.right);
            patchJump(skip);
        },
        .nullish => {
            // a ?? b : if a not null/undefined -> a; else b.
            // jump_nullish PEEKs (does not pop), so no dup needed.
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
        // For element/property stores the VM's set_elem/set_prop expect the
        // value on TOP of [obj(, key), val]. Emit obj/key first, then the value,
        // so no post-hoc stack rotation is needed (a plain `val; store` order
        // leaves [val, obj, key] which set_elem would read scrambled).
        if (lhs.tag == .computed_expr) {
            compileNode(lhs.left); // obj
            compileNode(lhs.right); // key
            compileNode(node.right); // val  → stack: [obj, key, val]
            emitOp(.set_elem);
            return;
        }
        if (lhs.tag == .member_expr) {
            compileNode(lhs.left); // obj
            compileNode(node.right); // val  → stack: [obj, val]
            // set_prop pops val (top) then obj — already in the right order.
            const prop_name = nameConstant(lhs.right);
            emitOp(.set_prop);
            emitU16(prop_name);
            return;
        }
        compileNode(node.right);
        compileStore(node.left);
        return;
    }

    // Compound assignment (+=, -=, etc.). For element/property targets the
    // obj (and key) must be evaluated ONCE and left on the stack in the exact
    // order set_elem/set_prop expect ([obj,key,val] / [obj,val]), otherwise the
    // store writes garbage. The old code re-evaluated the target in compileStore
    // AFTER the value was already on the stack, producing [val,obj,key] which
    // set_elem read scrambled (compound-assign to an array element silently did
    // nothing — this broke BotGuard's error-budget `H[0]-=X`).
    if (lhs.tag == .computed_expr) {
        // Layout target: [obj, key, newval]. Load current via dup of obj,key.
        compileNode(lhs.left); // [obj]
        compileNode(lhs.right); // [obj, key]
        emitOp(.dup2); // [obj, key, obj, key]
        emitOp(.get_elem); // [obj, key, cur]
        compileNode(node.right); // [obj, key, cur, rhs]
        emitCompoundOp(op_tt);
        emitOp(.set_elem); // [obj, key, newval] -> stores
        return;
    }
    if (lhs.tag == .member_expr) {
        const prop_name = nameConstant(lhs.right);
        compileNode(lhs.left); // [obj]
        emitOp(.dup); // [obj, obj]
        emitOp(.get_prop); // [obj, cur]
        emitU16(prop_name);
        compileNode(node.right); // [obj, cur, rhs]
        emitCompoundOp(op_tt);
        emitOp(.set_prop); // [obj, newval] -> stores
        emitU16(prop_name);
        return;
    }

    // Simple (identifier) target: load current value, apply op, store.
    compileNode(node.left); // load current value
    compileNode(node.right);
    emitCompoundOp(op_tt);
    compileStore(node.left);
}

fn emitCompoundOp(op_tt: TokenType) void {
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
            } else if (resolveUpvalue(name, cur_func)) |uv| {
                emitOp(.set_upval);
                emitU16(uv);
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
    const callee = parser.getNode(node.left);
    const arg_count = node.op;
    const args = parser.getList(node.right, @intCast(arg_count));
    const call_src_pos = lexer.getToken(node.token_idx).start;

    // Method call obj.m(args) / obj[k](args): thread the receiver as `this`.
    // Layout produced: [func][receiver][arg0..argN] then call_method.
    if (callee.tag == .member_expr) {
        compileNode(callee.left); // receiver
        emitOp(.dup); // [recv, recv]
        const name_const = nameConstant(callee.right);
        emitOp(.get_prop); // [recv, func]
        emitU16(name_const);
        emitOp(.swap); // [func, recv]
        for (args) |arg_idx| compileNode(arg_idx);
        cur_src_pos = call_src_pos;
        recordSrcPos(bc_len);
        emitOp(.call_method);
        emitByte(arg_count);
        return;
    }
    if (callee.tag == .computed_expr) {
        compileNode(callee.left); // receiver
        emitOp(.dup); // [recv, recv]
        compileNode(callee.right); // key
        emitOp(.get_elem); // [recv, func]
        emitOp(.swap); // [func, recv]
        for (args) |arg_idx| compileNode(arg_idx);
        cur_src_pos = call_src_pos;
        recordSrcPos(bc_len);
        emitOp(.call_method);
        emitByte(arg_count);
        return;
    }

    // Plain call. Detect DIRECT eval: callee is the bare identifier `eval`.
    // Direct eval inherits the caller's lexical scope; indirect eval (e.g.
    // `(0,eval)(x)`, `x.eval(y)`) runs in global scope. Only the bare-identifier
    // form is direct, so we emit a distinct opcode for it.
    var is_direct_eval = false;
    if (callee.tag == .identifier) {
        const ct = lexer.getToken(callee.token_idx);
        const cn = lexer.tokenText(ct);
        if (cn.len == 4 and cn[0] == 'e' and cn[1] == 'v' and cn[2] == 'a' and cn[3] == 'l') is_direct_eval = true;
    }
    // A function that CONTAINS a direct eval must retain its FULL lexical scope
    // at runtime (the eval'd code can reference ANY lexically-visible binding,
    // not just ones this function itself references). Mark the current nesting
    // level so compileFunctionBody force-captures all enclosing-scope locals as
    // upvalues — otherwise a builder like `function(T){return eval(T)}` closes
    // over nothing and the eval cannot see the interpreter's `f`/`K`/... .
    if (is_direct_eval and cur_func < MAX_FUNC_NEST) func_has_eval[cur_func] = true;

    compileNode(node.left); // callee
    for (args) |arg_idx| compileNode(arg_idx);
    cur_src_pos = call_src_pos;
    recordSrcPos(bc_len);
    emitOp(if (is_direct_eval) .call_direct_eval else .call);
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
    cur_src_pos = lexer.getToken(node.token_idx).start;
    recordSrcPos(bc_len);
    // DEBUG: capture the source position of any `.String` member compile.
    {
        const rt = lexer.getToken(parser.getNode(node.right).token_idx);
        const rn = lexer.tokenText(rt);
        if (eql(rn, "String") and dbg_dotstring_compile_n < dbg_dotstring_compile_pos.len) {
            dbg_dotstring_compile_pos[dbg_dotstring_compile_n] = lexer.getToken(node.token_idx).start;
            dbg_dotstring_compile_func[dbg_dotstring_compile_n] = cur_func;
            dbg_dotstring_compile_n += 1;
        }
    }
    emitOp(.get_prop);
    emitU16(name_const);
}
pub var dbg_dotstring_compile_pos: [16]u32 = [_]u32{0} ** 16;
pub var dbg_dotstring_compile_func: [16]u16 = [_]u16{0} ** 16;
pub var dbg_dotstring_compile_n: usize = 0;
pub fn dbgDotStringCompileN() usize { return dbg_dotstring_compile_n; }
pub fn dbgDotStringCompilePos(i: usize) u32 { return if (i < dbg_dotstring_compile_n) dbg_dotstring_compile_pos[i] else 0; }
pub fn dbgDotStringCompileFunc(i: usize) u16 { return if (i < dbg_dotstring_compile_n) dbg_dotstring_compile_func[i] else 0; }

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
    // `typeof x` must NOT throw when `x` is an undeclared global (unlike a bare
    // read). If the operand is a plain identifier that resolves to a global,
    // emit the non-throwing safe global read.
    const opnode = parser.getNode(node.left);
    if (opnode.tag == .identifier) {
        const tok = lexer.getToken(opnode.token_idx);
        const name = lexer.tokenText(tok);
        if (resolveLocal(name) == null and resolveUpvalue(name, cur_func) == null) {
            const idx = addStringConstant(name);
            emitOp(.get_global_safe);
            emitU16(idx);
            emitOp(.typeof_op);
            return;
        }
    }
    compileNode(node.left);
    emitOp(.typeof_op);
}

fn compileVoid(node: Node) void {
    compileNode(node.left);
    emitOp(.void_op);
}

fn compileDelete(node: Node) void {
    const t = parser.getNode(node.left);
    if (t.tag == .member_expr) {
        compileNode(t.left); // obj
        const name_const = nameConstant(t.right);
        emitOp(.del_prop);
        emitU16(name_const);
        return;
    }
    if (t.tag == .computed_expr) {
        compileNode(t.left); // obj
        compileNode(t.right); // key
        emitOp(.del_elem);
        return;
    }
    // delete of a non-reference: evaluate and yield true.
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

/// Function-wide `var` hoisting: recursively declare every `var`-declared name
/// (and hoisted function declarations) in a function body BEFORE compiling any
/// statements, so a nested function defined early can capture (as an upvalue)
/// an enclosing var that is only assigned later. Does NOT descend into nested
/// function/arrow bodies (they have their own scope). `let`/`const` are block
/// scoped and intentionally skipped here.
fn hoistVars(node_idx: NodeIdx) void {
    if (node_idx == NULL_NODE) return;
    const node = parser.getNode(node_idx);
    switch (node.tag) {
        .var_decl => {
            if (node.flags.is_let or node.flags.is_const) return;
            const list = parser.getList(node.left, @intCast(node.right));
            if (dbg_wtrack_char != 0 and list.len > dbg_hoist_max_listlen) dbg_hoist_max_listlen = @intCast(list.len);
            var h: usize = 0;
            while (h + 1 < list.len) : (h += 2) {
                const nm = list[h];
                if (nm == NULL_NODE) continue;
                const nn = parser.getNode(nm);
                if (nn.tag != .identifier) continue;
                const nt = lexer.getToken(nn.token_idx);
                if (dbg_wtrack_char != 0) { const tx = lexer.tokenText(nt); if (tx.len == 1 and tx[0] == dbg_wtrack_char) dbg_hoist_saw_w += 1; }
                if (resolveLocal(lexer.tokenText(nt)) == null) declareLocalFuncScoped(nm);
            }
        },
        .func_decl => {
            // `function name(){}` hoists `name` to function scope.
            if (node.left != NULL_NODE) {
                const nn = parser.getNode(node.left);
                if (nn.tag == .identifier) {
                    const nt = lexer.getToken(nn.token_idx);
                    if (resolveLocal(lexer.tokenText(nt)) == null) declareLocalFuncScoped(node.left);
                }
            }
        },
        .block => {
            const stmts = parser.getList(node.left, @intCast(node.right));
            for (stmts) |s| hoistVars(s);
        },
        .if_stmt => { hoistVars(node.right); hoistVars(node.extra); },
        .for_stmt => { hoistVars(node.left); hoistVars(node.right); },
        .for_in_stmt, .for_of_stmt => { hoistVars(node.left); hoistVars(node.right); },
        .while_stmt, .do_while_stmt => { hoistVars(node.right); },
        .with_stmt => { hoistVars(node.right); },
        .label_stmt => { hoistVars(node.left); },
        .try_stmt => {
            hoistVars(node.left); // try block
            // catch block body
            if (node.right != NULL_NODE) {
                const cnode = parser.getNode(node.right);
                const clist = parser.getList(cnode.left, @intCast(cnode.right));
                for (clist) |s| hoistVars(s);
            }
            // finally block
            const extras = parser.getList(node.extra, 2);
            if (extras.len > 1) hoistVars(extras[1]);
        },
        .switch_stmt => {
            const count = node.op;
            const cases = parser.getList(node.right, @intCast(count));
            for (cases) |case_idx| {
                const cnode = parser.getNode(case_idx);
                const body_count = cnode.op;
                const stmts = parser.getList(cnode.right, @intCast(body_count));
                for (stmts) |s| hoistVars(s);
            }
        },
        else => {}, // expr_stmt, return, etc. — no hoistable declarations
    }
}

fn bodyHasStrictDirective(body_idx: NodeIdx) bool {
    if (body_idx == NULL_NODE) return false;
    const body = parser.getNode(body_idx);
    if (body.tag != .block) return false;
    const stmts = parser.getList(body.left, @intCast(body.right));
    for (stmts) |stmt_idx| {
        const stmt = parser.getNode(stmt_idx);
        if (stmt.tag != .expr_stmt or stmt.left == NULL_NODE) break;
        const expr = parser.getNode(stmt.left);
        if (expr.tag != .literal_str) break;
        const raw = lexer.tokenText(lexer.getToken(expr.token_idx));
        if (eql(raw, "\"use strict\"") or eql(raw, "'use strict'")) return true;
    }
    return false;
}

fn compileFunctionBody(node: Node) u16 {
    if (n_functions >= MAX_FUNCTIONS) { had_error = true; return 0; }
    const func_id = n_functions;
    n_functions += 1;
    if (func_id == dbg_cfb_want) { dbg_cfb_seen = true; dbg_cfb_curfunc = cur_func; dbg_cfb_localcount = local_count; dbg_cfb_haderr = had_error; }
    if (cur_func < 16) dbg_cfb_hist[cur_func] += 1;

    // Save compiler state. NOTE: unlike the old design, we do NOT reset
    // local_count to 0. The enclosing function's locals stay live in locals[]
    // so resolveUpvalue can find (and capture) them. This function's locals
    // begin at local_base = local_count; resolveLocal only searches from there.
    const saved_locals = local_count;
    const saved_depth = scope_depth;
    const saved_bc = bc_len;
    const local_base = local_count;

    if (cur_func + 1 >= MAX_FUNC_NEST) { had_error = true; return func_id; }
    cur_func += 1;
    func_ctx_local_base[cur_func] = local_base;
    func_upval_count[cur_func] = 0;
    func_local_peak[cur_func] = local_base;
    func_has_eval[cur_func] = false;
    func_arguments_slot[cur_func] = 0xFFFF;
    func_uses_arguments[cur_func] = false;
    func_strict[cur_func] = func_strict[cur_func - 1] or bodyHasStrictDirective(node.right);
    scope_depth = 0;
    func_depth += 1;
    // Function bodies use normal expression-statement semantics (pop), even
    // when defined inside an eval body. Only the eval's own top-level uses the
    // completion register.
    const saved_eval_mode = eval_mode;
    eval_mode = false;
    // A function body is its own break/continue/loop context. Without this
    // isolation, a function defined inside a loop would share the enclosing
    // loop's break_patches/continue_patches, so the function's own break/
    // continue jumps get patched by the wrong (outer) loop — or never patched
    // at all, leaving dangling 0xFFFFFFFF jump targets that crash the VM.
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    const saved_loop_start = loop_start;
    const saved_label_base = label_base;
    const saved_loop_node = compiling_loop_node;
    const saved_jump_depths = [6]u16{ control_iter_depth, control_operand_depth, break_iter_depth, break_operand_depth, continue_iter_depth, continue_operand_depth };
    label_base = label_count;
    compiling_loop_node = NULL_NODE;
    control_iter_depth = 0; control_operand_depth = 0;
    break_iter_depth = 0; break_operand_depth = 0;
    continue_iter_depth = 0; continue_operand_depth = 0;
    loop_start = 0;

    // The function body is emitted inline. Jump over it so that sequential
    // (top-level / surrounding) execution does not fall through into the body;
    // the body is only entered via a call frame at code_start.
    const skip = emitJump(.jump);

    // Actual arguments begin after this. Reserve the ordinary function's
    // implicit binding before compiling nested closures so arrows can capture
    // it. The VM creates the object only when this binding is actually used.
    declareLocalDirect("this");

    // Params
    const param_count = node.op;
    const params = parser.getList(node.extra, @intCast(param_count));
    for (params) |p| {
        declareLocal(p);
    }
    if (resolveLocal("arguments") == null) {
        declareLocalDirect("arguments");
        func_arguments_slot[cur_func] = lastLocalSlot();
    }

    // Function body start in bytecode (entry point for calls).
    const code_start = bc_len;

    // Compile body
    if (node.right != NULL_NODE) {
        const body = parser.getNode(node.right);
        if (body.tag == .block) {
            // Function-wide var hoisting BEFORE compiling statements, so an
            // early nested function can capture a var assigned later.
            const stmts = parser.getList(body.left, @intCast(body.right));
            for (stmts) |s| hoistVars(s);
            for (stmts) |s| compileNode(s);
        } else {
            // Expression body (arrow)
            compileNode(node.right);
            emitOp(.ret);
        }
    }

    // Implicit return undefined
    emitOp(.ret_undef);

    // Patch the skip-jump to land here (just past the body).
    patchJump(skip);

    const code_len = bc_len - code_start;

    // Frame slot count = PEAK locals reached (not the final count). Block-scoped
    // let/const get popped by endScope, lowering local_count, but their slot
    // indices were already emitted into get_local/set_local; reserving only the
    // final count leaves those high slots unallocated, so a nested call's base
    // pointer overlaps them and corrupts captured variables.
    const frame_locals: u16 = func_local_peak[cur_func] - local_base;

    // Record this function's captured upvalue descriptors so the VM can build
    // the closure at make_func time.
    // If this function contains a direct eval, retain its full lexical scope by
    // capturing all enclosing locals as upvalues (done AFTER the body so every
    // enclosing local — including ones declared after this function — is visible).
    if (func_has_eval[cur_func]) captureAllEnclosingLocals();
    const n_uv = func_upval_count[cur_func];
    func_upval_desc_count[func_id] = n_uv;
    func_upval_desc_start[func_id] = n_upval_desc;
    {
        var ui: u16 = 0;
        while (ui < n_uv and n_upval_desc < MAX_UPVAL_DESC_POOL) : (ui += 1) {
            upval_desc_pool[n_upval_desc] = func_upvals[cur_func][ui];
            n_upval_desc += 1;
        }
    }

    // Persist this function's local-name table (frame-relative slot -> interned
    // name) for the VM's direct-eval caller-scope fallback.
    const nt_start = name_tab_used;
    var nt_count: u16 = 0;
    {
        var s: u16 = local_base;
        while (s < local_count and name_tab_used < MAX_NAME_TAB) : (s += 1) {
            const ln = locals[s];
            const name_idx: u32 = if (ln.name_len == 0) 0xFFFFFFFF else values.internString(localName(ln));
            name_tab_pool[name_tab_used] = name_idx;
            name_tab_used += 1;
            nt_count += 1;
        }
    }

    // Fill function descriptor
    functions[func_id] = .{
        .code_start = code_start,
        .code_len = code_len,
        .src_start = lexer.getToken(node.token_idx).start,
        .param_count = @intCast(param_count),
        .local_count = frame_locals,
        .upval_count = n_uv,
        .name_const = if (node.left != NULL_NODE) nameConstant(node.left) else 0xFFFF,
        .is_arrow = (node.tag == .arrow_expr),
        .is_async = node.flags.is_async,
        .is_generator = node.flags.is_generator,
        .arguments_slot = if (func_uses_arguments[cur_func] or func_has_eval[cur_func]) func_arguments_slot[cur_func] else 0xFFFF,
        .arguments_mapped = !func_strict[cur_func],
        .name_tab_start = nt_start,
        .name_tab_count = nt_count,
    };

    // Store the function's EXACT source text (for Function.prototype.toString /
    // `""+fn`). start = `function` keyword / arrow start token; end = node.end_pos
    // (just past the closing `}`). Copy into the source-text pool so it survives
    // after the (eval) source buffer is reused.
    {
        const start_tok = lexer.getToken(node.token_idx);
        const sstart: u32 = start_tok.start;
        const send: u32 = node.end_pos;
        if (send > sstart) {
            const text = lexer.sourceSlice(sstart, send);
            if (text.len > 0 and src_text_used + text.len <= MAX_SRC_TEXT) {
                const off = src_text_used;
                @memcpy(src_text_pool[off .. off + text.len], text);
                src_text_used += @intCast(text.len);
                functions[func_id].src_text_off = off;
                functions[func_id].src_text_len = @intCast(text.len);
            }
        }
    }

    // Debug: record nesting depth + first-param name per func_id so we can see
    // whether deep handlers (referencing `f`) are nested under their real parent
    // (`Tt`, 31 params) or flattened to depth 1 (the f->global scope bug).
    if (func_id < dbg_fnnest_cap) {
        dbg_fnnest_depth[func_id] = cur_func;
        dbg_fnnest_paramcount[func_id] = @intCast(param_count);
        dbg_fnnest_encbase[func_id] = if (cur_func > 0) func_ctx_local_base[cur_func - 1] else 0;
        dbg_fnnest_childbase[func_id] = func_ctx_local_base[cur_func];
        var fp: u8 = 0;
        if (param_count > 0 and params[0] != NULL_NODE) {
            const p0n = parser.getNode(params[0]);
            if (p0n.tag == .identifier) {
                const pt = lexer.getToken(p0n.token_idx);
                const ptx = lexer.tokenText(pt);
                if (ptx.len > 0) fp = ptx[0];
            }
        }
        dbg_fnnest_firstparam[func_id] = fp;
    }

    // Restore: pop this function's locals off the shared array.
    local_count = local_base;
    scope_depth = saved_depth;
    func_depth -|= 1;
    cur_func -= 1;
    eval_mode = saved_eval_mode;
    break_count = saved_breaks;
    continue_count = saved_continues;
    loop_start = saved_loop_start;
    label_base = saved_label_base;
    compiling_loop_node = saved_loop_node;
    control_iter_depth = saved_jump_depths[0]; control_operand_depth = saved_jump_depths[1];
    break_iter_depth = saved_jump_depths[2]; break_operand_depth = saved_jump_depths[3];
    continue_iter_depth = saved_jump_depths[4]; continue_operand_depth = saved_jump_depths[5];
    _ = saved_locals;
    _ = saved_bc;

    return func_id;
}

fn compileArrowBody(node: Node) u16 {
    if (n_functions >= MAX_FUNCTIONS) { had_error = true; return 0; }
    const func_id = n_functions;
    n_functions += 1;

    const saved_locals = local_count;
    const saved_depth = scope_depth;
    const local_base = local_count;
    if (cur_func + 1 >= MAX_FUNC_NEST) { had_error = true; return func_id; }
    cur_func += 1;
    func_ctx_local_base[cur_func] = local_base;
    func_upval_count[cur_func] = 0;
    func_local_peak[cur_func] = local_base;
    func_has_eval[cur_func] = false;
    func_arguments_slot[cur_func] = 0xFFFF;
    func_uses_arguments[cur_func] = false;
    func_strict[cur_func] = func_strict[cur_func - 1] or bodyHasStrictDirective(node.right);
    scope_depth = 0;
    func_depth += 1;
    const saved_eval_mode = eval_mode;
    eval_mode = false;
    // Isolate break/continue/loop context (see compileFunctionBody).
    const saved_breaks = break_count;
    const saved_continues = continue_count;
    const saved_loop_start = loop_start;
    const saved_label_base = label_base;
    const saved_loop_node = compiling_loop_node;
    const saved_jump_depths = [6]u16{ control_iter_depth, control_operand_depth, break_iter_depth, break_operand_depth, continue_iter_depth, continue_operand_depth };
    label_base = label_count;
    compiling_loop_node = NULL_NODE;
    control_iter_depth = 0; control_operand_depth = 0;
    break_iter_depth = 0; break_operand_depth = 0;
    continue_iter_depth = 0; continue_operand_depth = 0;
    loop_start = 0;

    // Jump over the inline body so surrounding execution doesn't fall through.
    const skip = emitJump(.jump);

    // Slot 0 is reserved for the callee/this by the VM call convention (args
    // begin at slot 1). Arrows ignore `this` but must keep slot 0 reserved so
    // parameter slots line up with how the VM lays out arguments.
    declareLocalDirect("this");

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
            for (stmts) |s| hoistVars(s);
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

    // Patch skip-jump to just past the body.
    patchJump(skip);

    const code_len = bc_len - code_start;

    const frame_locals: u16 = func_local_peak[cur_func] - local_base;

    // If this function contains a direct eval, retain its full lexical scope by
    // capturing all enclosing locals as upvalues (done AFTER the body so every
    // enclosing local — including ones declared after this function — is visible).
    if (func_has_eval[cur_func]) captureAllEnclosingLocals();
    const n_uv = func_upval_count[cur_func];
    func_upval_desc_count[func_id] = n_uv;
    func_upval_desc_start[func_id] = n_upval_desc;
    {
        var ui: u16 = 0;
        while (ui < n_uv and n_upval_desc < MAX_UPVAL_DESC_POOL) : (ui += 1) {
            upval_desc_pool[n_upval_desc] = func_upvals[cur_func][ui];
            n_upval_desc += 1;
        }
    }

    const nt_start = name_tab_used;
    var nt_count: u16 = 0;
    {
        var s: u16 = local_base;
        while (s < local_count and name_tab_used < MAX_NAME_TAB) : (s += 1) {
            const ln = locals[s];
            const name_idx: u32 = if (ln.name_len == 0) 0xFFFFFFFF else values.internString(localName(ln));
            name_tab_pool[name_tab_used] = name_idx;
            name_tab_used += 1;
            nt_count += 1;
        }
    }

    functions[func_id] = .{
        .code_start = code_start,
        .code_len = code_len,
        .src_start = lexer.getToken(node.token_idx).start,
        .param_count = @intCast(param_count),
        .local_count = frame_locals,
        .upval_count = n_uv,
        .name_const = 0xFFFF,
        .is_arrow = true,
        .is_async = node.flags.is_async,
        .is_generator = false,
        .name_tab_start = nt_start,
        .name_tab_count = nt_count,
    };

    // Store exact source text for toString (arrow). token_idx is near `=>`, so
    // this is best-effort for arrows; BotGuard's self-eval uses `function(...)`.
    {
        const start_tok = lexer.getToken(node.token_idx);
        const sstart: u32 = start_tok.start;
        const send: u32 = node.end_pos;
        if (send > sstart) {
            const text = lexer.sourceSlice(sstart, send);
            if (text.len > 0 and src_text_used + text.len <= MAX_SRC_TEXT) {
                const off = src_text_used;
                @memcpy(src_text_pool[off .. off + text.len], text);
                src_text_used += @intCast(text.len);
                functions[func_id].src_text_off = off;
                functions[func_id].src_text_len = @intCast(text.len);
            }
        }
    }

    local_count = local_base;
    scope_depth = saved_depth;
    func_depth -|= 1;
    cur_func -= 1;
    eval_mode = saved_eval_mode;
    break_count = saved_breaks;
    continue_count = saved_continues;
    loop_start = saved_loop_start;
    label_base = saved_label_base;
    compiling_loop_node = saved_loop_node;
    control_iter_depth = saved_jump_depths[0]; control_operand_depth = saved_jump_depths[1];
    break_iter_depth = saved_jump_depths[2]; break_operand_depth = saved_jump_depths[3];
    continue_iter_depth = saved_jump_depths[4]; continue_operand_depth = saved_jump_depths[5];
    _ = saved_locals;
    return func_id;
}

// ── Scope Helpers ──

fn beginScope() void {
    scope_depth += 1;
}

fn endScope() void {
    // Pop locals at the current block depth. Never pop below this function's
    // local_base (those belong to enclosing functions). Upvalue capture is
    // by-value (snapshot at make_func time), so there are no open upvalue cells
    // to "close" here — the old set_upval-on-pop stub is intentionally gone.
    const base = func_ctx_local_base[cur_func];
    while (local_count > base and locals[local_count - 1].depth >= scope_depth) {
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
    recordSlot15(tok);
    locals[local_count] = .{
        .name_start = tok.start,
        .name_len = tok.len,
        .depth = scope_depth,
        .is_captured = false,
    };
    local_count += 1;
    bumpLocalPeak();
}

// Record the NAME of any local that lands at relative slot 15 in a 31-param
// function (Tt), to find the param-K collision.
pub var dbg_s15_n: u32 = 0;
pub var dbg_s15_name_start: [16]u32 = [_]u32{0} ** 16;
pub var dbg_s15_name_len: [16]u32 = [_]u32{0} ** 16;
pub var dbg_s15_depth: [16]u16 = [_]u16{0} ** 16;
pub var dbg_s15_names: [16][15]u8 = [_][15]u8{[_]u8{0} ** 15} ** 16;
pub var dbg_s15_curfunc: [16]u16 = [_]u16{0} ** 16;
pub fn dbgS15Name(i: usize) []const u8 { return dbg_s15_names[i][0..dbg_s15_name_len[i]]; }
pub fn dbgS15CurFunc(i: usize) u16 { return dbg_s15_curfunc[i]; }
fn recordSlot15(tok: anytype) void {
    const base = func_ctx_local_base[cur_func];
    const rel = local_count - base;
    const pc = if (cur_func < MAX_FUNC_NEST) func_local_peak[cur_func] else 0;
    _ = pc;
    // Only for slot 15; store the name bytes directly (offsets don't survive).
    if (rel == 15 and dbg_s15_n < 16) {
        const nm = lexer.tokenText(tok);
        const kk = @min(nm.len, 15);
        @memcpy(dbg_s15_names[dbg_s15_n][0..kk], nm[0..kk]);
        dbg_s15_name_len[dbg_s15_n] = @intCast(kk);
        dbg_s15_depth[dbg_s15_n] = scope_depth;
        dbg_s15_curfunc[dbg_s15_n] = cur_func;
        dbg_s15_n += 1;
    }
}
pub fn dbgS15N() u32 { return dbg_s15_n; }
pub fn dbgS15NameStart(i: usize) u32 { return dbg_s15_name_start[i]; }
pub fn dbgS15NameLen(i: usize) u32 { return dbg_s15_name_len[i]; }
pub fn dbgS15Depth(i: usize) u16 { return dbg_s15_depth[i]; }

/// Declare a function-scoped local (for hoisted `var` / function declarations).
/// Recorded at depth 0 so inner block `endScope()` never pops it — matching
/// JS `var` function-scope semantics (a `var` declared inside a block remains
/// visible after the block ends).
fn declareLocalFuncScoped(name_node_idx: NodeIdx) void {
    if (name_node_idx == NULL_NODE) return;
    const name_node = parser.getNode(name_node_idx);
    if (name_node.tag != .identifier) return;
    const tok = lexer.getToken(name_node.token_idx);
    if (dbg_wtrack_char != 0 and tok.len == 1) {
        const nm = lexer.tokenText(tok);
        if (nm.len == 1 and nm[0] == dbg_wtrack_char) {
            dbg_wdecl_count += 1;
            dbg_wdecl_last_curfunc = cur_func;
            dbg_wdecl_last_localcount = local_count;
            if (local_count >= MAX_LOCALS) dbg_wdecl_dropped_maxlocals += 1;
        }
    }
    if (local_count >= MAX_LOCALS) return;
    recordSlot15(tok);
    locals[local_count] = .{
        .name_start = tok.start,
        .name_len = tok.len,
        .depth = 0, // function scope — never popped by inner endScope
        .is_captured = false,
    };
    local_count += 1;
    bumpLocalPeak();
}
pub var dbg_wtrack_char: u8 = 0;
pub var dbg_wdecl_count: u32 = 0;
pub var dbg_wdecl_last_curfunc: u16 = 0;
pub var dbg_wdecl_last_localcount: u16 = 0;
pub var dbg_wdecl_dropped_maxlocals: u32 = 0;

fn declareLocalDirect(name: []const u8) void {
    if (local_count >= MAX_LOCALS) return;
    locals[local_count] = .{
        .name_len = @intCast(name.len),
        .name_idx = values.internString(name),
        .depth = scope_depth,
        .is_captured = false,
    };
    local_count += 1;
    bumpLocalPeak();
}

/// Frame-relative slot of the most recently declared local (i.e. the slot to
/// emit for the local at `local_count - 1`), relative to the current function's
/// base pointer. Locals below `local_base` belong to enclosing functions.
fn lastLocalSlot() u16 {
    const base = func_ctx_local_base[cur_func];
    if (local_count <= base) return 0;
    return (local_count - 1) - base;
}

/// Resolve `name` to a frame-relative local slot within the CURRENT function
/// only (search [local_base .. local_count]). Returns the slot relative to bp,
/// or null if the name is not a local of this function.
fn resolveLocal(name: []const u8) ?u16 {
    const base = func_ctx_local_base[cur_func];
    if (local_count <= base) return null;
    var i: u16 = local_count;
    while (i > base) {
        i -= 1;
        const local = locals[i];
        const local_name = localName(local);
        if (eql(local_name, name)) {
            const slot = i - base;
            if (eql(name, "arguments") and slot == func_arguments_slot[cur_func]) func_uses_arguments[cur_func] = true;
            return slot;
        }
    }
    return null;
}

/// Resolve `name` as an upvalue of the function at nesting index `level`.
/// Returns the upvalue index within that function's upvalue list, or null.
///
/// Standard "crafting interpreters" algorithm, adapted to the flat locals[]
/// array + fixed-size context stack:
///   - level 0 has no enclosing function → no upvalues.
///   - Search the ENCLOSING function's locals; if found, mark it captured and
///     add a {is_local:true, index:<enclosing frame-relative slot>} upvalue.
///   - Else recurse into the enclosing function; if that yields an upvalue, add
///     a {is_local:false, index:<parent upvalue index>} upvalue (a "transitive"
///     capture that threads the value down through each intermediate closure).
fn resolveUpvalue(name: []const u8, level: u16) ?u16 {
    if (level == 0) {
        // Base case. In a DIRECT eval compile the eval body (level 0) has no
        // lexical parent FUNCTION in this compilation unit, but it DOES inherit
        // the eval-caller's scope. Resolve the free name against the caller's
        // locals/upvalues and register it as an eval-body caller-scope upvalue.
        if (eval_caller_active) return resolveEvalCaller(name);
        return null;
    }
    const enclosing = level - 1;
    const enc_base = func_ctx_local_base[enclosing];
    // The enclosing function's locals occupy [enc_base .. child_base), where
    // child_base is this function's local_base.
    const child_base = func_ctx_local_base[level];

    // 1) Direct capture: name is a local of the immediately enclosing function.
    var i: u16 = child_base;
    while (i > enc_base) {
        i -= 1;
        const local = locals[i];
        const local_name = localName(local);
        if (eql(local_name, name)) {
            locals[i].is_captured = true;
            const rel: u16 = i - enc_base; // enclosing frame-relative slot
            if (eql(name, "arguments") and rel == func_arguments_slot[enclosing]) func_uses_arguments[enclosing] = true;
            return addUpvalueNamed(level, rel, true, values.internString(name));
        }
    }

    // 2) Transitive capture: found as an upvalue further up the chain.
    if (resolveUpvalue(name, enclosing)) |parent_idx| {
        return addUpvalueNamed(level, parent_idx, false, values.internString(name));
    }
    // Debug: record the first failed upvalue resolution for a watched 1-char
    // name so we can see enc_base/child_base/level when `w` falls through to
    // global (the IIFE upvalue-capture bug).
    if (!dbg_uvfail_captured and name.len == 1 and name[0] == dbg_uvfail_char) {
        dbg_uvfail_captured = true;
        dbg_uvfail_level = level;
        dbg_uvfail_enc_base = enc_base;
        dbg_uvfail_child_base = child_base;
        dbg_uvfail_local_count = local_count;
        dbg_uvfail_cur_func = cur_func;
        dbg_uvfail_func_depth = func_depth;
        // Scan the ENTIRE locals[] array for the watched name to see if it was
        // ever declared as a local anywhere (and at which slot), independent of
        // the level ranges — this tells us if the name exists but the range/base
        // bookkeeping is wrong, vs it was never declared as a local at all.
        dbg_uvfail_found_slot = 0xFFFF;
        var s: u16 = 0;
        while (s < local_count) : (s += 1) {
            const ln = localName(locals[s]);
            if (eql(ln, name)) { dbg_uvfail_found_slot = s; break; }
        }
        // Snapshot func_ctx_local_base for all active levels.
        var lv: u16 = 0;
        while (lv <= cur_func and lv < 16) : (lv += 1) { dbg_uvfail_bases[lv] = func_ctx_local_base[lv]; }
        dbg_uvfail_bases_n = @min(cur_func + 1, 16);
    }
    return null;
}
pub var dbg_uvfail_captured: bool = false;
pub var dbg_uvfail_char: u8 = 0;
pub var dbg_uvfail_level: u16 = 0;
pub var dbg_uvfail_enc_base: u16 = 0;
pub var dbg_uvfail_child_base: u16 = 0;
pub var dbg_uvfail_local_count: u16 = 0;
pub var dbg_uvfail_cur_func: u16 = 0;
pub var dbg_uvfail_func_depth: u16 = 0;
pub var dbg_uvfail_found_slot: u16 = 0xFFFF;
pub var dbg_uvfail_bases: [16]u16 = [_]u16{0} ** 16;
pub var dbg_uvfail_bases_n: u16 = 0;

// Per-func_id nesting diagnostics (see compileFunctionBody).
pub const dbg_fnnest_cap: u16 = 512;
pub var dbg_fnnest_depth: [dbg_fnnest_cap]u16 = [_]u16{0} ** dbg_fnnest_cap;
pub var dbg_fnnest_paramcount: [dbg_fnnest_cap]u8 = [_]u8{0} ** dbg_fnnest_cap;
pub var dbg_fnnest_firstparam: [dbg_fnnest_cap]u8 = [_]u8{0} ** dbg_fnnest_cap;
pub var dbg_fnnest_encbase: [dbg_fnnest_cap]u16 = [_]u16{0} ** dbg_fnnest_cap;
pub var dbg_fnnest_childbase: [dbg_fnnest_cap]u16 = [_]u16{0} ** dbg_fnnest_cap;
pub fn dbgFnnestDepth(i: usize) u16 { return dbg_fnnest_depth[i % dbg_fnnest_cap]; }
pub fn dbgFnnestParam(i: usize) u8 { return dbg_fnnest_paramcount[i % dbg_fnnest_cap]; }
pub fn dbgFnnestFirstParam(i: usize) u8 { return dbg_fnnest_firstparam[i % dbg_fnnest_cap]; }
pub fn dbgFnnestEncBase(i: usize) u16 { return dbg_fnnest_encbase[i % dbg_fnnest_cap]; }
pub fn dbgFnnestChildBase(i: usize) u16 { return dbg_fnnest_childbase[i % dbg_fnnest_cap]; }

/// Resolve a free identifier in a DIRECT eval body against the eval-caller's
/// lexical scope. Registers the capture as an eval-body caller-scope upvalue and
/// returns its index in func_upvals[0], or null if the name is not found in the
/// caller scope (so the identifier falls through to a real global).
///   - Caller LOCAL: `resolveLocalNameInFunc(caller, name)` -> frame slot; the VM
///     binds this eval-body upvalue to the live caller frame's `bp + slot`.
///   - Caller UPVALUE: the name matches one of the caller function's upvalues
///     (by name); the VM binds it by sharing the caller closure's cell.
fn resolveEvalCaller(name: []const u8) ?u16 {
    if (!eval_caller_active or eval_caller_func == 0xFFFF or eval_caller_func >= n_functions) return null;
    dbg_evalcap_n += 1;
    const name_idx = values.internString(name);
    // 1) Caller's own locals (params + declared locals), by name.
    if (resolveLocalNameInFunc(eval_caller_func, name_idx)) |slot| {
        dbg_evalcap_local += 1;
        return addEvalUpvalue(slot, EVAL_UV_CALLER_LOCAL, name_idx);
    }
    // 2) Caller's upvalues, by name (transitive lexical chain above the caller).
    const cnt = func_upval_desc_count[eval_caller_func];
    var i: u16 = 0;
    while (i < cnt) : (i += 1) {
        const uv = upval_desc_pool[func_upval_desc_start[eval_caller_func] + i];
        if (uv.name == name_idx) {
            dbg_evalcap_upval += 1;
            return addEvalUpvalue(i, EVAL_UV_CALLER_UPVAL, name_idx);
        }
    }
    dbg_evalcap_miss += 1;
    return null;
}

/// Force the CURRENT function (cur_func) to capture EVERY distinct name visible
/// in its enclosing lexical scopes as an upvalue. Called for functions that
/// contain a DIRECT eval, whose eval'd code may reference any enclosing binding.
/// Walks enclosing locals nearest-first (so the nearest binding of a shadowed
/// name wins, matching lexical scope) and routes each through resolveUpvalue to
/// build the proper (possibly transitive) capture chain.
fn captureAllEnclosingLocals() void {
    const my_base = func_ctx_local_base[cur_func];
    // Enclosing locals occupy [0 .. my_base). Walk nearest (highest slot) first.
    var i: u16 = my_base;
    while (i > 0) {
        i -= 1;
        const ln = locals[i];
        if (ln.name_len == 0) continue;
        const nm = localName(ln);
        if (nm.len == 0) continue;
        // resolveUpvalue dedups, so re-capturing an already-captured name is a
        // no-op. This creates the transitive chain from cur_func up to the owner.
        _ = resolveUpvalue(nm, cur_func);
    }
    // A function compiled inside direct eval can inherit bindings that live in
    // the eval caller's closure rather than in this compilation's local table.
    // Nested direct eval must retain those bindings too, even when its source
    // does not mention them until runtime.
    if (eval_caller_active and eval_caller_func < n_functions) {
        const caller = functions[eval_caller_func];
        var li: u16 = 0;
        while (li < caller.name_tab_count) : (li += 1) {
            const ni = name_tab_pool[caller.name_tab_start + li];
            if (ni != 0xFFFFFFFF) _ = resolveUpvalue(values.getString(ni), cur_func);
        }
        var ui: u16 = 0;
        while (ui < func_upval_desc_count[eval_caller_func]) : (ui += 1) {
            const uv = upval_desc_pool[func_upval_desc_start[eval_caller_func] + ui];
            if (uv.name != 0xFFFFFFFF) _ = resolveUpvalue(values.getString(uv.name), cur_func);
        }
    }
}

/// Add (dedup) an upvalue to the function at nesting index `level`. Returns its
/// index within that function's upvalue list. `name` is the interned name of the
/// captured variable (for eval caller-scope resolution by name).
fn addUpvalueNamed(level: u16, index: u16, is_local: bool, name: u32) ?u16 {
    if (level >= MAX_FUNC_NEST) return null;
    const count = func_upval_count[level];
    var k: u16 = 0;
    while (k < count) : (k += 1) {
        const uv = func_upvals[level][k];
        if (uv.index == index and uv.is_local == is_local and uv.eval_kind == EVAL_UV_NORMAL) return k;
    }
    if (count >= MAX_UPVALS) return null;
    func_upvals[level][count] = .{ .index = index, .is_local = is_local, .name = name, .eval_kind = EVAL_UV_NORMAL };
    func_upval_count[level] = count + 1;
    return count;
}

fn addUpvalue(level: u16, index: u16, is_local: bool) ?u16 {
    return addUpvalueNamed(level, index, is_local, 0xFFFFFFFF);
}

/// Add (dedup) a DIRECT-EVAL caller-scope upvalue to the eval body's own upvalue
/// list (level 0 of an eval compile). `eval_kind` selects whether `index` refers
/// to a caller-frame LOCAL slot or a caller-closure UPVALUE index. `name` is the
/// captured variable's interned name. Returns the eval-body upvalue index.
fn addEvalUpvalue(index: u16, eval_kind: u8, name: u32) ?u16 {
    const level: u16 = 0; // eval body is always compiled at nesting level 0
    const count = func_upval_count[level];
    var k: u16 = 0;
    while (k < count) : (k += 1) {
        const uv = func_upvals[level][k];
        if (uv.eval_kind == eval_kind and uv.index == index) return k;
    }
    if (count >= MAX_UPVALS) return null;
    func_upvals[level][count] = .{ .index = index, .is_local = false, .name = name, .eval_kind = eval_kind };
    func_upval_count[level] = count + 1;
    return count;
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

/// Emit a 32-bit little-endian operand. Used exclusively for control-flow
/// targets (jumps, loop back-edges, try catch/finally offsets) so that code
/// compiled/appended beyond bytecode offset 65535 (e.g. large eval'd BotGuard
/// payloads) keeps correct jump targets. Non-jump operands stay u16.
fn emitU32(val: u32) void {
    emitByte(@intCast(val & 0xFF));
    emitByte(@intCast((val >> 8) & 0xFF));
    emitByte(@intCast((val >> 16) & 0xFF));
    emitByte(@intCast((val >> 24) & 0xFF));
}

fn emitJump(op: Op) u32 {
    emitOp(op);
    const pos = bc_len;
    emitU32(0xFFFFFFFF); // placeholder (4-byte absolute target)
    return pos;
}

fn patchJump(offset: u32) void {
    patchJumpTo(offset, bc_len);
}

fn patchJumpTo(offset: u32, target: u32) void {
    if (offset + 3 >= MAX_BYTECODE) return;
    // Absolute bytecode offset, full 32-bit — no saturation. MAX_BYTECODE is
    // 512KB (< 2^32), so any valid target fits without truncation.
    bytecode[offset] = @intCast(target & 0xFF);
    bytecode[offset + 1] = @intCast((target >> 8) & 0xFF);
    bytecode[offset + 2] = @intCast((target >> 16) & 0xFF);
    bytecode[offset + 3] = @intCast((target >> 24) & 0xFF);
}

fn emitLoop(target: u32) void {
    emitOp(.loop_back);
    // Relative backward distance (4-byte). +4 accounts for the operand width
    // consumed by this loop_back instruction.
    const offset: u32 = bc_len - target + 4;
    emitU32(offset);
}

fn patchBreaks(saved: u16) void {
    var read = saved;
    var write = saved;
    while (read < break_count) : (read += 1) {
        if (break_labels[read] == NO_LABEL) patchJump(break_patches[read]) else {
            break_patches[write] = break_patches[read];
            break_labels[write] = break_labels[read];
            write += 1;
        }
    }
    break_count = write;
}

fn patchLabelBreaks(saved: u16, label: u16) void {
    var read = saved;
    var write = saved;
    while (read < break_count) : (read += 1) {
        if (break_labels[read] == label) patchJump(break_patches[read]) else {
            break_patches[write] = break_patches[read];
            break_labels[write] = break_labels[read];
            write += 1;
        }
    }
    break_count = write;
}

fn patchContinues(saved: u16, target: u32) void {
    var read = saved;
    var write = saved;
    while (read < continue_count) : (read += 1) {
        const label = continue_labels[read];
        if (label == NO_LABEL or label_scopes[label].loop_node == compiling_loop_node) patchJumpTo(continue_patches[read], target) else {
            continue_patches[write] = continue_patches[read];
            continue_labels[write] = continue_labels[read];
            write += 1;
        }
    }
    continue_count = write;
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
