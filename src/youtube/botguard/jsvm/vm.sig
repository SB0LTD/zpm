// @zpm/youtube/botguard/jsvm/vm — Bytecode Interpreter
//
// Stack-based virtual machine that executes compiled JavaScript bytecode.
// Features: value stack, call frames, closures, exception handling, GC-free.
//
// Memory model:
//   - Value stack: 4096 entries (64KB)
//   - Call frames: 256 deep
//   - Exception frames: 64 deep
//   - All fixed-size, no allocation during execution

const compiler = @import("compiler.sig");
const values = @import("values.sig");
const objects = @import("objects.sig");
const lexer = @import("lexer.sig");
const parser = @import("parser.sig");
const builtins = @import("builtins.sig");
const env = @import("env.sig");
const Op = compiler.Op;
const Value = values.Value;

// ── Configuration ──

// Stack must hold every live frame's locals + operands. BotGuard's module IIFE
// declares 100+ locals in a single frame, and nested calls stack more, so 4096
// overflowed. Keep within u16 addressing (sp/bp are u16).
pub const MAX_STACK: usize = 32768;
pub const MAX_FRAMES: usize = 512;
// BotGuard's interpreter (vb) is called recursively and each iteration wraps a
// try/catch (register-fault lazy init relies on it). A 64-frame cap silently
// dropped try frames on deep recursion; a later leave_try then popped the wrong
// frame, so a thrown TypeError (e.g. `undefined.apply` in an opcode handler)
// found no catch and became fatal. Size for deep nesting.
pub const MAX_TRY_FRAMES: usize = 8192;

// ── Call Frame ──

pub const CallFrame = struct {
    func_id: u16 = 0, // function descriptor index
    ip: u32 = 0, // instruction pointer (offset in bytecode)
    bp: u16 = 0, // base pointer (stack offset for locals)
    closure_obj: u32 = objects.NULL_OBJ, // function object being executed (for upvalues)
    is_constructor: bool = false,
    // Direct-eval scope inheritance: for a frame produced by (or lexically
    // descended from) a DIRECT `eval(src)`, this points at the frame that CALLED
    // eval (bp + closure). A free identifier that is not a global resolves
    // against that caller frame's locals/upvalues by name (JS direct-eval scope).
    // 0xFFFF = none. Set on the eval frame and inherited by functions it creates.
    eval_caller_frame: u16 = 0xFFFF,
    eval_caller_bp: u16 = 0,
    eval_caller_closure: u32 = objects.NULL_OBJ,
    eval_caller_func: u16 = 0xFFFF,
    // Each eval invocation retains its own statement completion. Nested evals
    // and callbacks must not overwrite the outer body's most recent value.
    eval_completion: Value = Value.UNDEFINED,
};

// ── Exception Frame ──

const TryFrame = struct {
    catch_ip: u32 = 0,
    finally_ip: u32 = 0,
    frame_depth: u16 = 0, // call frame depth when try was entered
    stack_depth: u16 = 0, // stack depth when try was entered
    start_ip: u32 = 0,
    end_ip: u32 = 0,
};

// ── VM State ──

var stack: [MAX_STACK]Value = undefined;
var sp: u16 = 0; // stack pointer

var frames: [MAX_FRAMES]CallFrame = undefined;
var frame_count: u16 = 0;

// Per-frame constructor tracking: if frame i is a `new` call, ctor_is[i] is
// true and ctor_new_obj[i] holds the object to return when the constructor
// returns a non-object value.
var ctor_is: [MAX_FRAMES]bool = undefined;
var ctor_new_obj: [MAX_FRAMES]u32 = undefined;

var try_frames: [MAX_TRY_FRAMES]TryFrame = undefined;
var try_count: u16 = 0;

// for-in / for-of iterator stack. Each iterator snapshots an object's key
// count (for-in) or array length (for-of) and walks a position.
const MAX_ITERS: usize = 64;
const IterState = struct {
    keys: [objects.MAX_ENUM_KEYS]u32 = undefined,
    obj_idx: u32 = 0,
    pos: u32 = 0,
    count: u32 = 0,
    is_array: bool = false, // iterate values (of) vs keys (in)
    valid: bool = false,
};
var iters: [MAX_ITERS]IterState = undefined;
var iter_count: u16 = 0;

var global_obj: u32 = objects.NULL_OBJ; // global object index
var had_error: bool = false;
var error_value: Value = Value.UNDEFINED;
const CompletionKind = enum { normal, exception, return_value, jump };
const AbruptCompletion = struct {
    kind: CompletionKind = .normal,
    value: Value = Value.UNDEFINED,
    target: u32 = 0,
    stack_depth: u16 = 0,
};
const FinallyContext = struct {
    frame_depth: u16,
    start_ip: u32,
    end_ip: u32,
    action: AbruptCompletion,
    statement_completion: Value,
};
var finally_contexts: [MAX_TRY_FRAMES]FinallyContext = undefined;
var finally_count: u16 = 0;
var staged_completion: ?AbruptCompletion = null;
pub var dbg_finally_unwind: u32 = 0;
pub fn dbgFinallyUnwind() u32 { return dbg_finally_unwind; }
// Record user-call target names while enabled (for tracing the snapshot).
pub var dbg_callrec_on: bool = false;
pub var dbg_lastW_tag: u8 = 255;
pub var dbg_lastW_reads: u32 = 0;
pub var dbg_lastW_str: [96]u8 = undefined;
pub var dbg_lastW_str_len: usize = 0;
pub fn dbgLastWTag() u8 { return dbg_lastW_tag; }
pub fn dbgLastWReads() u32 { return dbg_lastW_reads; }
pub fn dbgLastWStr() []const u8 { return dbg_lastW_str[0..dbg_lastW_str_len]; }
var dbg_callrec_names: [512]u32 = [_]u32{0} ** 512;
var dbg_callrec_arg0: [512]i64 = [_]i64{-999999} ** 512;
var dbg_callrec_n: usize = 0;
pub fn dbgCallrecReset() void { dbg_callrec_n = 0; }
pub fn dbgCallrecCount() usize { return dbg_callrec_n; }
pub fn dbgCallrecName(i: usize) []const u8 { if (i >= dbg_callrec_n) return ""; return if (dbg_callrec_names[i] == 0) "?" else values.getString(dbg_callrec_names[i]); }
pub fn dbgCallrecArg0(i: usize) i64 { if (i >= dbg_callrec_n) return -999999; return dbg_callrec_arg0[i]; }
// Distinct native func_ids invoked while recording (for detecting whether the
// vmSetup/telemetry/logger callbacks are ever reached).
var dbg_native_ids: [64]u16 = [_]u16{0} ** 64;
var dbg_native_ids_n: usize = 0;
fn dbgRecordNative(fid: u16) void {
    for (0..dbg_native_ids_n) |i| if (dbg_native_ids[i] == fid) return;
    if (dbg_native_ids_n < dbg_native_ids.len) { dbg_native_ids[dbg_native_ids_n] = fid; dbg_native_ids_n += 1; }
}
pub fn dbgNativeIdsReset() void { dbg_native_ids_n = 0; }
pub fn dbgNativeIdsCount() usize { return dbg_native_ids_n; }
pub fn dbgNativeId(i: usize) u16 { if (i >= dbg_native_ids_n) return 0; return dbg_native_ids[i]; }
pub var dbg_atob_lookups: u32 = 0;
pub fn dbgAtobLookups() u32 { return dbg_atob_lookups; }
/// Expose a function value's func_id (for diagnostics).
pub fn dbgFuncIdOf(v: Value) u16 {
    if (v.tag != .function) return 0xFFFF;
    const o = objects.getObject(@intCast(v.data.func_idx));
    return o.func_id;
}

/// True if writing `newval` to global `name_str` would overwrite the native VM
/// intrinsics `eval`/`Function` with a NON-function value. In real JS these are
/// only ever shadowed lexically (e.g. `var eval="x"` inside a scope), never
/// globally replaced by a string. Our flat-global model would otherwise let a
/// scope-local `var eval="..."` (executed by eval'd code, which we run with
/// global var scope) clobber the native eval, breaking every subsequent direct
/// eval (it would call a string and yield undefined). Protecting the intrinsic
/// keeps direct eval working, matching the reference.
fn wouldClobberIntrinsic(name_str: u32, newval: Value) bool {
    const nm = values.getString(name_str);
    if (!eql(nm, "eval") and !eql(nm, "Function")) return false;
    if (newval.tag == .function) return false; // legitimate function reassignment
    const cur = objects.getProperty(global_obj, name_str);
    if (cur.tag != .function) return false;
    return builtins.isVmIntrinsic(dbgFuncIdOf(cur));
}
/// Expose a function's declared local_count/param_count.
pub fn dbgFuncLocalsOf(v: Value) u16 {
    if (v.tag != .function) return 0;
    const o = objects.getObject(@intCast(v.data.func_idx));
    if (o.func_id >= 0xF000) return 0;
    return compiler.getFunction(o.func_id).local_count;
}
// Track the function with the most params/locals entered while recording (the
// interpreter setup QU has ~32 params) — its entry count and how far its ip got.
pub var dbg_bigfn_id: u16 = 0xFFFF;
pub var dbg_bigfn_locals: u16 = 0;
pub var dbg_bigfn_entries: u32 = 0;
pub var dbg_bigfn_maxip: u32 = 0;
pub var dbg_bigfn_retok: u32 = 0; // times it ran to a ret
pub fn dbgBigFn() [5]u32 { return .{ dbg_bigfn_id, dbg_bigfn_locals, dbg_bigfn_entries, dbg_bigfn_maxip, dbg_bigfn_retok }; }
var dbg_steplimit_op: [80]u8 = [_]u8{0} ** 80;
var dbg_steplimit_op_n: usize = 0;
var dbg_steplimit_func: u16 = 0;
var dbg_steplimit_ip: u32 = 0;
pub fn dbgSteplimitOpCount() usize { return dbg_steplimit_op_n; }
pub fn dbgSteplimitOpName(i: usize) []const u8 { if (i >= dbg_steplimit_op_n) return ""; return @tagName(@as(Op, @enumFromInt(dbg_steplimit_op[i]))); }
pub fn dbgSteplimitFunc() u16 { return dbg_steplimit_func; }
pub fn dbgSteplimitIp() u32 { return dbg_steplimit_ip; }
var dbg_firstpropthrow_captured: bool = false;
var dbg_firstpropthrow_name: u32 = 0;
var dbg_firstpropthrow_recv: u32 = 0;
var dbg_firstpropthrow_isnull: bool = false;
var dbg_firstpropthrow_func: u16 = 0;
var dbg_fpt_l0: u32 = 0;
var dbg_fpt_l1: u32 = 0;
var dbg_fpt_l2: u32 = 0;
var dbg_fpt_l3: u32 = 0;
var dbg_fpt_l4: u32 = 0;
var dbg_fpt_l5: u32 = 0;
pub fn dbgFptName() []const u8 { return if (dbg_firstpropthrow_name == 0) "" else values.getString(dbg_firstpropthrow_name); }
pub fn dbgFptRecv() []const u8 { return if (dbg_firstpropthrow_recv == 0) "" else values.getString(dbg_firstpropthrow_recv); }
pub fn dbgFptIsNull() bool { return dbg_firstpropthrow_isnull; }
pub fn dbgFptFunc() u16 { return dbg_firstpropthrow_func; }
pub fn dbgFptL(i: usize) []const u8 { const v = switch (i) { 0 => dbg_fpt_l0, 1 => dbg_fpt_l1, 2 => dbg_fpt_l2, 3 => dbg_fpt_l3, 4 => dbg_fpt_l4, else => dbg_fpt_l5 }; return if (v == 0) "" else values.getString(v); }
var dbg_fpt_op: [80]u8 = [_]u8{0} ** 80;
var dbg_fpt_op_n: usize = 0;
pub fn dbgFptOpCount() usize { return dbg_fpt_op_n; }
pub fn dbgFptOpName(i: usize) []const u8 { if (i >= dbg_fpt_op_n) return ""; return @tagName(@as(Op, @enumFromInt(dbg_fpt_op[i]))); }
// eval completion register: holds the value of the last expression statement
// evaluated inside an eval body (see compiler set_completion/get_completion).
var completion: Value = Value.UNDEFINED;
var error_reason: []const u8 = "";
var dbg_enter_try: u32 = 0;
var dbg_throw: u32 = 0;
pub fn dbgEnterTry() u32 { return dbg_enter_try; }
pub fn dbgThrowCount() u32 { return dbg_throw; }
var dbg_first_throw_tag: u8 = 255;
var dbg_first_throw_num: i64 = -1;
var dbg_first_throw_e0: i64 = -9;
var dbg_first_throw_e1: i64 = -9;
pub fn dbgFirstThrow() [4]i64 { return .{ dbg_first_throw_tag, dbg_first_throw_num, dbg_first_throw_e0, dbg_first_throw_e1 }; }
pub fn dbgResetFirstThrow() void { dbg_first_throw_tag = 255; dbg_first_throw_num = -1; dbg_first_throw_e0 = -9; dbg_first_throw_e1 = -9; dbg_first_throwex_tag = 255; dbg_first_throwex_num = -1; dbg_throwex_count = 0; }
pub var dbg_disable_instanceof: bool = false;
pub var dbg_disable_call_recv: bool = false;
pub var dbg_trayride_setprop_count: u32 = 0;
pub var dbg_trayride_target_tag: u8 = 255;
pub var dbg_trayride_target_obj: u16 = 0xFFFF;
pub var dbg_trayride_set_nameidx: u32 = 0xFFFFFFFF;
pub var dbg_trayride_val_tag: u8 = 255;
pub fn dbgTrayrideSet() [5]u32 { return .{ dbg_trayride_setprop_count, dbg_trayride_target_tag, dbg_trayride_target_obj, dbg_trayride_set_nameidx, dbg_trayride_val_tag }; }
pub fn getGlobalObjIdx() u32 { return global_obj; }
pub fn dbgInternTrayride() u32 { return values.internString("trayride"); }
/// Read the global's "trayride" prop directly by the set-time name index.
pub fn dbgGlobalTrayrideByIdx(idx: u32) u8 { return @intFromEnum(objects.getProperty(global_obj, idx).tag); }
var dbg_first_throwex_tag: u8 = 255;
var dbg_first_throwex_num: i64 = -1;
var dbg_throwex_count: u32 = 0;
pub fn dbgThrowEx() [3]i64 { return .{ dbg_first_throwex_tag, dbg_first_throwex_num, dbg_throwex_count }; }
// Track DISTINCT register indices `z` from [op,30,z] register-void faults.
// If distinct count << total count, registers never "stick" (resolve-loop bug).
// If distinct ~= total, decode/position advance is wrong.
var dbg_regfault_seen: [65536]bool = [_]bool{false} ** 65536;
var dbg_regfault_distinct: u32 = 0;
var dbg_regfault_total: u32 = 0;
var dbg_regfault_first_z: i64 = -1;
var dbg_regfault_first5: [5]i64 = [_]i64{ -1, -1, -1, -1, -1 };
var dbg_regfault_first5_n: usize = 0;
pub fn dbgRegFault() [3]i64 { return .{ dbg_regfault_distinct, dbg_regfault_total, dbg_regfault_first_z }; }
pub fn dbgRegFaultFirst5(i: usize) i64 { if (i >= 5) return -1; return dbg_regfault_first5[i]; }
var dbg_eval_calls: u32 = 0;
var dbg_eval_compiled: u32 = 0;
var dbg_user_calls: u32 = 0;
// Per-func_id call histogram (functions get sequential compiler ids). Used to
// see which user functions run during the register-fault resolve loop.
pub var dbg_Tget_count: u32 = 0;
pub var dbg_Tget_last_owner: u32 = 0xFFFFFFFF;
pub var dbg_Tget_last_arr: u32 = 0xFFFFFFFF;
pub fn dbgTGet() [3]u32 { return .{ dbg_Tget_count, dbg_Tget_last_owner, dbg_Tget_last_arr }; }
var dbg_length_name_idx: u32 = 0xFFFFFFFF;
pub var dbg_S_name_idx: u32 = 0xFFFFFFFF;
pub var dbg_S_set_count: u32 = 0;
pub var dbg_S_last_val: i64 = -1;
pub var dbg_S_last_tag: u8 = 255;
pub fn dbgS() [3]i64 { return .{ dbg_S_set_count, dbg_S_last_val, dbg_S_last_tag }; }
pub var dbg_rD_name_idx: u32 = 0xFFFFFFFF;
pub var dbg_rD_set_count: u32 = 0;
pub var dbg_rD_last_owner: u32 = 0xFFFFFFFF;
pub var dbg_rD_last_val: u32 = 0xFFFFFFFF;
pub fn dbgRD() [3]u32 { return .{ dbg_rD_set_count, dbg_rD_last_owner, dbg_rD_last_val }; }
pub var dbg_Y_name_idx: u32 = 0xFFFFFFFF;
pub var dbg_Y_set_count: u32 = 0;
pub var dbg_Y_last_val: i64 = -1;
pub var dbg_ox_name_idx: u32 = 0xFFFFFFFF;
pub var dbg_ox_set_count: u32 = 0;
pub var dbg_ox_last_len: u32 = 0;
pub fn dbgYox() [4]i64 { return .{ dbg_Y_set_count, dbg_Y_last_val, dbg_ox_set_count, dbg_ox_last_len }; }
pub var dbg_T_name_idx: u32 = 0xFFFFFFFF;
pub var dbg_T_reassign_count: u32 = 0;
pub var dbg_T_last_owner: u32 = 0xFFFFFFFF;
pub var dbg_T_last_arr: u32 = 0xFFFFFFFF;
pub fn dbgTReassign() [3]u32 { return .{ dbg_T_reassign_count, dbg_T_last_owner, dbg_T_last_arr }; }
pub var dbg_T_hist_owner: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_T_hist_arr: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_T_hist_setelem: [16]u32 = [_]u32{0} ** 16;
pub var dbg_T_hist_arrlen: [16]u32 = [_]u32{0} ** 16;
pub var dbg_T_hist_func: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_T_hist_n: usize = 0;
pub fn dbgTHist2(i: usize, se: *u32, al: *u32, fid: *u32) bool { if (i >= dbg_T_hist_n) return false; se.* = dbg_T_hist_setelem[i]; al.* = dbg_T_hist_arrlen[i]; fid.* = dbg_T_hist_func[i]; return true; }
pub fn dbgTHist(i: usize, owner: *u32, arr: *u32) bool { if (i >= dbg_T_hist_n) return false; owner.* = dbg_T_hist_owner[i]; arr.* = dbg_T_hist_arr[i]; return true; }
pub var dbg_setelem_numeric: u32 = 0;
pub var dbg_setelem_total: u32 = 0;
pub var dbg_se_obj: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_se_obj_cnt: [16]u32 = [_]u32{0} ** 16;
pub var dbg_se_obj_func: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_se_obj_n: usize = 0;
pub fn dbgSeObj(i: usize, obj: *u32, cnt: *u32, fid: *u32) bool { if (i >= dbg_se_obj_n) return false; obj.* = dbg_se_obj[i]; cnt.* = dbg_se_obj_cnt[i]; fid.* = dbg_se_obj_func[i]; return true; }
pub var dbg_setelem_last_key: i64 = -1;
pub var dbg_setelem_last_obj: u32 = 0xFFFFFFFF;
pub var dbg_setelem_last_valtag: u8 = 255;
pub fn dbgSetElem() [4]i64 { return .{ dbg_setelem_numeric, dbg_setelem_last_key, dbg_setelem_last_obj, dbg_setelem_last_valtag }; }
pub var dbg_fidhist: [4096]u32 = [_]u32{0} ** 4096;
pub var dbg_fidhist_all: [4096]u32 = [_]u32{0} ** 4096;
pub fn dbgFidHistAll(i: usize) u32 { if (i >= dbg_fidhist_all.len) return 0; return dbg_fidhist_all[i]; }
pub fn dbgFidHist(i: usize) u32 { if (i >= dbg_fidhist.len) return 0; return dbg_fidhist[i]; }
pub fn dbgFidHistTop(out_ids: *[12]u32, out_cnts: *[12]u32) void {
    // Simple top-12 by count.
    var i: usize = 0;
    while (i < 12) : (i += 1) { out_ids[i] = 0xFFFFFFFF; out_cnts[i] = 0; }
    var f: usize = 0;
    while (f < dbg_fidhist.len) : (f += 1) {
        const c = dbg_fidhist[f];
        if (c == 0) continue;
        // insertion into top list
        var slot: usize = 12;
        var j: usize = 0;
        while (j < 12) : (j += 1) { if (c > out_cnts[j]) { slot = j; break; } }
        if (slot < 12) {
            var k: usize = 11;
            while (k > slot) : (k -= 1) { out_cnts[k] = out_cnts[k-1]; out_ids[k] = out_ids[k-1]; }
            out_cnts[slot] = c; out_ids[slot] = @intCast(f);
        }
    }
}
var dbg_native_calls: u32 = 0;
var dbg_notcallable: u32 = 0;

// Name (string pool index) of the most recent global/property lookup, so a
// not-callable failure can report which identifier was invoked.
var last_lookup_name: u32 = 0;
// The lookup name immediately BEFORE the current one — for `X.call()` the
// receiver `X` was looked up just before `call`, so this tells us what `X` was.
var prev_lookup_name: u32 = 0;
// Ring buffer of recent lookup names, for reconstructing the access path that
// led to a not-callable failure.
var lookup_ring: [12]u32 = [_]u32{0} ** 12;
var lookup_ring_pos: usize = 0;
// Scratch buffers for Function.prototype.apply/call argument spreading. Sized to
// hold a large `.apply(this, bigArray)` (BotGuard base64-encodes via
// `String.fromCharCode.apply(null, byteChunk)` with up to 8192-element chunks).
// Module-level (not on the Zig call stack) to avoid a 128KB+ stack frame.
// Each active apply owns its argument span while getters/coercions reenter JS.
var fnapply_storage: [32768]Value = undefined;
var fnapply_used: usize = 0;
fn setLookupName(name_idx: u32) void {
    prev_lookup_name = last_lookup_name;
    last_lookup_name = name_idx;
    lookup_ring[lookup_ring_pos % lookup_ring.len] = name_idx;
    lookup_ring_pos += 1;
}
/// Return the i-th most-recent lookup name (0 = most recent).
pub fn dbgRecentLookup(i: usize) []const u8 {
    if (i >= lookup_ring.len or i >= lookup_ring_pos) return "";
    const idx = (lookup_ring_pos - 1 - i) % lookup_ring.len;
    if (lookup_ring[idx] == 0) return "";
    return values.getString(lookup_ring[idx]);
}
// Record up to N distinct not-callable names for diagnostics.
const MAX_NC_NAMES: usize = 32;
var nc_names: [MAX_NC_NAMES]u32 = undefined;
var nc_name_count: usize = 0;

// Capture context of the FIRST method not-callable: receiver tag, method name,
// and up to 8 own-property names of the receiver, so we can tell which object
// the failing `x.method()` was actually invoked on.
var dbg_ncm_captured: bool = false;
var dbg_ncm_recv_tag: u8 = 255;
var dbg_ncm_recv_objtype: u8 = 255;
var dbg_ncm_recv_proto: u32 = 0xFFFF;
var dbg_ncm_recv_arrlen: u32 = 0;
var dbg_ncm_proto_has_concat: u8 = 0; // 0 absent,1 data,2 getter,3 setter in chain
pub var dbg_lastuv_func: u16 = 0xFFFF;
pub var dbg_lastuv_idx: u16 = 0xFFFF;
pub var dbg_lastuv_closed: bool = false;
pub var dbg_lastuv_addr: u32 = 0xFFFFFFFF;
pub var dbg_lastuv_closure: u32 = 0xFFFFFFFF;
pub var dbg_lastuv_upcount: u16 = 0;
pub fn dbgLastUv() [6]u32 { return .{ dbg_lastuv_func, dbg_lastuv_idx, if (dbg_lastuv_closed) @as(u32,1) else 0, dbg_lastuv_addr, dbg_lastuv_closure, dbg_lastuv_upcount }; }
pub var dbg_lastuv_readtag: u8 = 255;
pub var dbg_binding_name: ?[]const u8 = null;
pub var dbg_binding_count: usize = 0;
pub var dbg_binding_closure: [256]u32 = undefined;
pub var dbg_binding_index: [256]u16 = undefined;
pub var dbg_binding_initial: [256]Value = undefined;
pub var dbg_binding_write_count: usize = 0;
pub var dbg_binding_write_func: [64]u16 = undefined;
pub var dbg_binding_write_ip: [64]u32 = undefined;
pub var dbg_binding_write_value: [64]Value = undefined;

pub fn dbgBindingValue(closure: u32, index: u16) Value {
    if (objects.isClosureUpvalClosed(closure, index)) return objects.getClosureUpvalClosedVal(closure, index);
    const addr = objects.getClosureUpvalAddr(closure, index);
    return if (addr < MAX_STACK) stack[addr] else Value.UNDEFINED;
}
pub fn dbgLastUvReadTag() u8 { return dbg_lastuv_readtag; }
// Capture the first get_upval that reads a long (program) string.
pub var dbg_badupval_done: bool = false;
pub var dbg_badupval_func: u16 = 0xFFFF;
pub var dbg_badupval_idx: u16 = 0;
pub var dbg_badupval_closure: u32 = 0;
pub var dbg_badupval_upcount: u16 = 0;
pub var dbg_badupval_slen: u32 = 0;
pub var dbg_badupval_closed: u8 = 0;
pub fn dbgBadUpval() [6]u32 { return .{ if (dbg_badupval_done) 1 else 0, dbg_badupval_func, dbg_badupval_idx, dbg_badupval_upcount, dbg_badupval_slen, dbg_badupval_closed }; }
// PINPOINT: bank-field ('H'/'O') read off a FUNCTION receiver (op-64 handler's
// bad K flowing into D). Captured once.
pub var dbg_fnbank_done: bool = false;
pub var dbg_fnbank_func: u16 = 0xFFFF;
pub var dbg_fnbank_closure: u32 = 0;
pub var dbg_fnbank_upcount: u16 = 0;
pub var dbg_fnbank_funcidx: u32 = 0;
pub var dbg_fnbank_prevop: u8 = 0;
pub var dbg_fnbank_uvidx: u16 = 0xFFFF;
pub var dbg_fnbank_caller: u16 = 0xFFFF;
pub var dbg_fnbank_caller_closure: u32 = 0;
pub var dbg_fnbank_caller_upcount: u16 = 0;
pub fn dbgFnbank() [6]u32 { return .{ if (dbg_fnbank_done) 1 else 0, dbg_fnbank_func, dbg_fnbank_upcount, dbg_fnbank_funcidx, dbg_fnbank_prevop, dbg_fnbank_uvidx }; }
pub fn dbgFnbankCaller() [3]u32 { return .{ dbg_fnbank_caller, dbg_fnbank_caller_upcount, dbg_fnbank_caller_closure }; }
var dbg_ncm_recv_objidx: u32 = 0xFFFFFFFF;
var dbg_ncm_recv_wasnullset: bool = false;
var dbg_ncm_uv_func: u16 = 0xFFFF;
var dbg_ncm_uv_idx: u16 = 0xFFFF;
var dbg_ncm_uv_closed: bool = false;
var dbg_ncm_uv_addr: u32 = 0xFFFFFFFF;
var dbg_ncm_uv_stackval: u8 = 255;
pub fn dbgNcmUv() [5]u32 { return .{ dbg_ncm_uv_func, dbg_ncm_uv_idx, if (dbg_ncm_uv_closed) @as(u32,1) else 0, dbg_ncm_uv_addr, dbg_ncm_uv_stackval }; }
pub fn dbgNcmRecvInfo() [4]u32 { return .{ dbg_ncm_recv_objtype, dbg_ncm_recv_proto, dbg_ncm_recv_arrlen, dbg_ncm_proto_has_concat }; }
pub fn dbgNcmRecvIdx() u32 { return dbg_ncm_recv_objidx; }
pub fn dbgNcmRecvWasNullSet() bool { return dbg_ncm_recv_wasnullset; }
var dbg_ncm_method: u32 = 0;
var dbg_ncm_prop_count: usize = 0;
var dbg_ncm_props: [8]u32 = undefined;
var dbg_ncm_method_present: bool = false;
var dbg_ncm_recv_name: u32 = 0;
var dbg_ncm_ring: [12]u32 = [_]u32{0} ** 12;
var dbg_ncm_ring_n: usize = 0;
var dbg_ncm_func_id: u16 = 0;
var dbg_ncm_ip: usize = 0;
pub fn dbgNcmFuncId() u16 { return dbg_ncm_func_id; }
pub fn dbgNcmIp() usize { return dbg_ncm_ip; }
pub fn dbgNcmFuncSrcStart() u32 {
    if (dbg_ncm_func_id == 0xFFFF or dbg_ncm_func_id == 0xFFFE) return 0;
    return compiler.getFunction(dbg_ncm_func_id).src_start;
}
// First "read a property off undefined/null" occurrence.
// Targeted per-function opcode trace (set dbg_ftrace_func + enable).
pub var dbg_ftrace_enabled: bool = false;
pub var dbg_ftrace_func: u16 = 0xFFFF;
pub var dbg_ftrace_op: [128]u8 = [_]u8{0} ** 128;
pub var dbg_ftrace_ip: [128]u32 = [_]u32{0} ** 128;
pub var dbg_ftrace_n: usize = 0;
pub fn dbgFtraceCount() usize { return dbg_ftrace_n; }
pub fn dbgFtraceOpName(i: usize) []const u8 { if (i >= dbg_ftrace_n) return ""; return @tagName(@as(Op, @enumFromInt(dbg_ftrace_op[i]))); }
pub fn dbgFtraceIp(i: usize) u32 { if (i >= dbg_ftrace_n) return 0; return dbg_ftrace_ip[i]; }
fn frame_code_start(frame: *CallFrame) u32 {
    if (frame.func_id == 0xFFFF or frame.func_id == 0xFFFE) return 0;
    return compiler.getFunction(frame.func_id).code_start;
}
var op_ring: [80]u8 = [_]u8{0} ** 80;
var op_ring_ip: [80]u32 = [_]u32{0} ** 80;
var op_ring_pos: usize = 0;
// Snapshot of op ring at the not-callable moment.
var dbg_ncm_op_ring: [80]u8 = [_]u8{0} ** 80;
var dbg_ncm_op_ip: [80]u32 = [_]u32{0} ** 80;
var dbg_ncm_op_n: usize = 0;
pub fn dbgNcmOpCount() usize { return dbg_ncm_op_n; }
pub fn dbgNcmOpName(i: usize) []const u8 {
    if (i >= dbg_ncm_op_n) return "";
    return @tagName(@as(Op, @enumFromInt(dbg_ncm_op_ring[i])));
}
pub fn dbgNcmOpIp(i: usize) u32 { if (i >= dbg_ncm_op_n) return 0; return dbg_ncm_op_ip[i]; }

// Provenance of the receiver for the first `.prototype`-off-undefined.
var dbg_recvprov_captured: bool = false;
var dbg_recvprov_op: u8 = 255;
var dbg_recvprov_upval_idx: u16 = 0xFFFF;
var dbg_recvprov_upval_closed: bool = false;
var dbg_recvprov_closure: u32 = 0xFFFF;
var dbg_recvprov_upval_count: u16 = 0;
var dbg_recvprov_slot: u16 = 0xFFFF;
var dbg_recvprov_upval_addr: u32 = 0;
var dbg_recvprov_addr_tag: u8 = 255;
var dbg_recvprov_cur_bp: u16 = 0;
var dbg_recvprov_cur_sp: u16 = 0;
var dbg_recvprov_ud_islocal: bool = false;
var dbg_recvprov_ud_index: u16 = 0;
var dbg_recvprov_owner_func: u16 = 0xFFFF;
var dbg_recvprov_owner_bp: u16 = 0;
var dbg_recvprov_owner_lc: u16 = 0;
pub fn dbgRecvProvOwnerFunc() u16 { return dbg_recvprov_owner_func; }
pub fn dbgRecvProvOwnerBp() u16 { return dbg_recvprov_owner_bp; }
pub fn dbgRecvProvOwnerLc() u16 { return dbg_recvprov_owner_lc; }
// Detect the first time a new frame's bp lands inside the parent frame's
// reserved local region (stack overlap / aliasing bug).
pub var dbg_overlap_detected: bool = false;
var dbg_overlap_child_bp: u16 = 0;
var dbg_overlap_parent_bp: u16 = 0;
var dbg_overlap_parent_lc: u16 = 0;
var dbg_overlap_parent_func: u16 = 0;
var dbg_overlap_child_func: u16 = 0;
var dbg_overlap_parent_sp: u16 = 0;
pub fn dbgOverlap() [6]u32 { return .{ if (dbg_overlap_detected) 1 else 0, dbg_overlap_child_bp, dbg_overlap_parent_bp, dbg_overlap_parent_lc, dbg_overlap_parent_func, dbg_overlap_child_func }; }
pub fn dbgOverlapParentSp() u16 { return dbg_overlap_parent_sp; }
fn checkFrameOverlap(child_bp: u16, child_func: u16) void {
    if (dbg_overlap_detected or frame_count == 0) return;
    // Check against ALL ancestor frames: the child's [bp, ...) must start at or
    // above every live ancestor's reserved local region end.
    var fi: usize = 0;
    while (fi < frame_count) : (fi += 1) {
        const anc = frames[fi];
        if (anc.func_id == 0xFFFF or anc.func_id == 0xFFFE) continue; // top-level/eval
        const alc = compiler.getFunction(anc.func_id).local_count;
        if (child_bp >= anc.bp and child_bp < @as(u32, anc.bp) + alc) {
            dbg_overlap_detected = true;
            dbg_overlap_child_bp = child_bp;
            dbg_overlap_parent_bp = anc.bp;
            dbg_overlap_parent_lc = alc;
            dbg_overlap_parent_func = anc.func_id;
            dbg_overlap_child_func = child_func;
            dbg_overlap_parent_sp = sp;
            return;
        }
    }
}
pub fn dbgRecvProvOp() []const u8 { if (dbg_recvprov_op == 255) return "(none)"; return @tagName(@as(Op, @enumFromInt(dbg_recvprov_op))); }
pub fn dbgRecvProvUpvalIdx() u16 { return dbg_recvprov_upval_idx; }
pub fn dbgRecvProvUpvalClosed() bool { return dbg_recvprov_upval_closed; }
pub fn dbgRecvProvUpvalCount() u16 { return dbg_recvprov_upval_count; }
pub fn dbgRecvProvSlot() u16 { return dbg_recvprov_slot; }
pub fn dbgRecvProvUpvalAddr() u32 { return dbg_recvprov_upval_addr; }
pub fn dbgRecvProvAddrTag() u8 { return dbg_recvprov_addr_tag; }
pub fn dbgRecvProvBp() u16 { return dbg_recvprov_cur_bp; }
pub fn dbgRecvProvSp() u16 { return dbg_recvprov_cur_sp; }
pub fn dbgRecvProvUdIsLocal() bool { return dbg_recvprov_ud_islocal; }
pub fn dbgRecvProvUdIndex() u16 { return dbg_recvprov_ud_index; }
// Capture: an is_local upvalue whose index exceeds the creating frame's locals.
var dbg_mkuv_captured: bool = false;
var dbg_mkuv_func: u16 = 0;
var dbg_mkuv_bp: u16 = 0;
var dbg_mkuv_lc: u16 = 0;
var dbg_mkuv_index: u16 = 0;
var dbg_mkuv_childfunc: u16 = 0;
pub fn dbgMkuv() [6]u32 { return .{ if (dbg_mkuv_captured) 1 else 0, dbg_mkuv_func, dbg_mkuv_bp, dbg_mkuv_lc, dbg_mkuv_index, dbg_mkuv_childfunc }; }
// Trace make_func is_local captures (addr/bp/idx/sp/valtag) when enabled.
pub var dbg_mkuv_trace: bool = false;
pub var dbg_mkuv_trace_n: u32 = 0;
pub var dbg_mkuv_trace_addr: [8]u32 = [_]u32{0} ** 8;
pub var dbg_mkuv_trace_bp: [8]u16 = [_]u16{0} ** 8;
pub var dbg_mkuv_trace_idx: [8]u16 = [_]u16{0} ** 8;
pub var dbg_mkuv_trace_sp: [8]u32 = [_]u32{0} ** 8;
pub var dbg_mkuv_trace_valtag: [8]u8 = [_]u8{0} ** 8;
pub fn dbgMkuvTraceReset() void { dbg_mkuv_trace_n = 0; dbg_mkuv_trace = true; }
pub fn dbgMkuvTraceN() u32 { return dbg_mkuv_trace_n; }
pub fn dbgMkuvTraceAddr(i: usize) u32 { return dbg_mkuv_trace_addr[i]; }
pub fn dbgMkuvTraceBp(i: usize) u16 { return dbg_mkuv_trace_bp[i]; }
pub fn dbgMkuvTraceIdx(i: usize) u16 { return dbg_mkuv_trace_idx[i]; }
pub fn dbgMkuvTraceValtag(i: usize) u8 { return dbg_mkuv_trace_valtag[i]; }
pub fn dbgMkuvTraceCell(i: usize) u32 { return dbg_mkuv_trace_sp[i]; }
// Full descriptor capture for ONE target closure (n_uv >= min).
pub var dbg_mkuv_done: bool = false;
pub var dbg_mkuv_min_uv: u16 = 4;
pub var dbg_mkuv_want_params: u16 = 0xFFFF;
pub var dbg_mkuv_want_func: u16 = 0xFFFF;
pub var dbg_mkuv_target_func: u16 = 0xFFFF;
pub var dbg_mkuv_target_nuv: u16 = 0;
pub var dbg_mkuv_target_bp: u16 = 0;
pub var dbg_mkuv_d_islocal: [16]u8 = [_]u8{0} ** 16;
pub var dbg_mkuv_d_index: [16]u16 = [_]u16{0} ** 16;
pub var dbg_mkuv_d_valtag: [16]u8 = [_]u8{0} ** 16;
pub var dbg_mkuv_d_addr: [16]u32 = [_]u32{0} ** 16;
pub var dbg_mkuv_frameslot: [32]u8 = [_]u8{0} ** 32;
pub var dbg_mkuv_encl_func: u16 = 0xFFFF;
pub var dbg_mkuv_encl_lc: u16 = 0;
pub var dbg_mkuv_encl_pc: u16 = 0;
pub fn dbgMkuvEnclFunc() u16 { return dbg_mkuv_encl_func; }
pub fn dbgMkuvEnclLc() u16 { return dbg_mkuv_encl_lc; }
pub fn dbgMkuvEnclPc() u16 { return dbg_mkuv_encl_pc; }
// Watch writes to a specific absolute stack address (Tt's K slot).
pub var dbg_slot15_watch: u32 = 0xFFFFFFFF;
// Func-filtered `t` write trace (483 slot 9).
pub var dbg_twrite_func: u16 = 0xFFFF;
pub var dbg_twrite_slot: u16 = 0xFFFF;
pub var dbg_twrite_n: u32 = 0;
pub var dbg_twrite_tag: [24]u8 = [_]u8{255} ** 24;
pub var dbg_twrite_ip: [24]u32 = [_]u32{0} ** 24;
pub var dbg_twrite_num: [24]f64 = [_]f64{-987654.0} ** 24;
pub var dbg_twrite_objtype: [24]u8 = [_]u8{255} ** 24;
pub var dbg_twrite_str: [24][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 24;
pub var dbg_twrite_slen: [24]usize = [_]usize{0} ** 24;
pub var dbg_twrite_y: [24]i32 = [_]i32{-1} ** 24;
pub var dbg_twrite_xobj: [24]u32 = [_]u32{0xFFFFFFFF} ** 24;
pub var dbg_badcell_captured: bool = false;
pub var dbg_badcell_tag: u8 = 255;
pub var dbg_badcell_obj: u32 = 0xFFFFFFFF;
pub var dbg_badcell_objtype: u8 = 255;
pub var dbg_badcell_create_fid: u16 = 0xFFFF;
pub var dbg_badcell_g_tag: u8 = 255;
pub var dbg_badcell_g_str: [32]u8 = undefined;
pub var dbg_badcell_g_slen: usize = 0;
pub var dbg_badcell_proto_tag: u8 = 255;
pub var dbg_badcell_proto_hasown: u8 = 0;
pub var dbg_badcell_proto_str: [32]u8 = undefined;
pub var dbg_badcell_proto_slen: usize = 0;
pub var dbg_badcell_value_tag: u8 = 255;
pub var dbg_badcell_value_hasown: u8 = 0;
pub var dbg_badcell_proto_fid: u16 = 0xFFFF;
pub var dbg_badcell_proto_getter_fid: u16 = 0xFFFF;
pub fn dbgBadcellProtoFid() u16 { return dbg_badcell_proto_fid; }
pub fn dbgBadcellProtoGetterFid() u16 { return dbg_badcell_proto_getter_fid; }
pub fn dbgBadcellProtoTag() u8 { return dbg_badcell_proto_tag; }
pub fn dbgBadcellProtoHasOwn() u8 { return dbg_badcell_proto_hasown; }
pub fn dbgBadcellProtoStr() []const u8 { return dbg_badcell_proto_str[0..dbg_badcell_proto_slen]; }
pub fn dbgBadcellValueTag() u8 { return dbg_badcell_value_tag; }
pub fn dbgBadcellValueHasOwn() u8 { return dbg_badcell_value_hasown; }
pub fn dbgBadcellTag() u8 { return dbg_badcell_tag; }
pub fn dbgBadcellObj() u32 { return dbg_badcell_obj; }
pub fn dbgBadcellObjType() u8 { return dbg_badcell_objtype; }
pub fn dbgBadcellCreateFid() u16 { return dbg_badcell_create_fid; }
pub fn dbgBadcellGTag() u8 { return dbg_badcell_g_tag; }
pub fn dbgBadcellGStr() []const u8 { return dbg_badcell_g_str[0..dbg_badcell_g_slen]; }
pub fn dbgTwriteY(i: usize) i32 { return dbg_twrite_y[i % 24]; }
pub fn dbgTwriteXObj(i: usize) u32 { return dbg_twrite_xobj[i % 24]; }
pub fn dbgTwriteN() u32 { return dbg_twrite_n; }
pub fn dbgTwriteTag(i: usize) u8 { return dbg_twrite_tag[i % 24]; }
pub fn dbgTwriteIp(i: usize) u32 { return dbg_twrite_ip[i % 24]; }
pub fn dbgTwriteNum(i: usize) f64 { return dbg_twrite_num[i % 24]; }
pub fn dbgTwriteObjType(i: usize) u8 { return dbg_twrite_objtype[i % 24]; }
pub fn dbgTwriteStr(i: usize) []const u8 { return dbg_twrite_str[i % 24][0..dbg_twrite_slen[i % 24]]; }
pub var dbg_slot15_n: u32 = 0;
pub var dbg_slot15_func: [16]u16 = [_]u16{0} ** 16;
pub var dbg_slot15_slot: [16]u16 = [_]u16{0} ** 16;
pub var dbg_slot15_tag: [16]u8 = [_]u8{0} ** 16;
pub var dbg_slot15_ip: [16]u32 = [_]u32{0} ** 16;
pub var dbg_slot15_slen: [16]u32 = [_]u32{0} ** 16;
pub fn dbgSlot15N() u32 { return dbg_slot15_n; }
pub fn dbgSlot15Func(i: usize) u16 { return dbg_slot15_func[i]; }
pub fn dbgSlot15Slot(i: usize) u16 { return dbg_slot15_slot[i]; }
pub fn dbgSlot15Tag(i: usize) u8 { return dbg_slot15_tag[i]; }
pub fn dbgSlot15Ip(i: usize) u32 { return dbg_slot15_ip[i]; }
pub fn dbgSlot15Slen(i: usize) u32 { return dbg_slot15_slen[i]; }
pub fn dbgMkuvDValtag(i: usize) u8 { return dbg_mkuv_d_valtag[i]; }
pub fn dbgMkuvDAddr(i: usize) u32 { return dbg_mkuv_d_addr[i]; }
pub fn dbgMkuvFrameSlot(i: usize) u8 { return dbg_mkuv_frameslot[i]; }
pub fn dbgMkuvTargetFunc() u16 { return dbg_mkuv_target_func; }
pub fn dbgMkuvTargetNuv() u16 { return dbg_mkuv_target_nuv; }
pub fn dbgMkuvTargetBp() u16 { return dbg_mkuv_target_bp; }
pub fn dbgMkuvDIsLocal(i: usize) u8 { return dbg_mkuv_d_islocal[i]; }
pub fn dbgMkuvDIndex(i: usize) u16 { return dbg_mkuv_d_index[i]; }
// Trace closeUpvalues events when enabled.
pub var dbg_closetrace: bool = false;
pub var dbg_closetrace_n: u32 = 0;
pub var dbg_closetrace_addr: [8]u32 = [_]u32{0} ** 8;
pub var dbg_closetrace_min: [8]u32 = [_]u32{0} ** 8;
pub var dbg_closetrace_valtag: [8]u8 = [_]u8{0} ** 8;
pub fn dbgCloseTraceReset() void { dbg_closetrace_n = 0; dbg_closetrace = true; }
pub fn dbgCloseTraceN() u32 { return dbg_closetrace_n; }
pub fn dbgCloseTraceAddr(i: usize) u32 { return dbg_closetrace_addr[i]; }
pub fn dbgCloseTraceMin(i: usize) u32 { return dbg_closetrace_min[i]; }
pub fn dbgCloseTraceValtag(i: usize) u8 { return dbg_closetrace_valtag[i]; }
// Watch a function's first frame entry (bp, sp after reservation, local_count).
pub var dbg_entry_watch_func: u16 = 0xFFFF;
pub var dbg_entry_watch_need_undef2: bool = false; // only capture when param slot 2 is undefined
pub var dbg_jlog_func: u16 = 0xFFFF; // func id whose first 40 calls' (n, bankTag) to log
pub var dbg_jlog_n: u32 = 0;
pub var dbg_jlog_n_arr: [40]u32 = [_]u32{0} ** 40;
pub var dbg_jlog_s_tag: [40]u8 = [_]u8{255} ** 40;
pub var dbg_jret_n: u32 = 0;
pub var dbg_jret_tag: [40]u8 = [_]u8{255} ** 40;
pub var dbg_jret_num: [40]f64 = [_]f64{0} ** 40;
pub var dbg_jlog_total: u32 = 0;
pub var dbg_jbad_captured: bool = false;
pub var dbg_jbad_callidx: u32 = 0;
pub var dbg_jbad_n: u32 = 0;
pub var dbg_jbad_s_tag: u8 = 255;
pub var dbg_jbad_caller_func: u16 = 0xFFFF;
pub var dbg_jbad_caller_ip: u32 = 0;
var dbg_entry_captured: bool = false;
var dbg_entry_bp: u16 = 0;
var dbg_entry_sp: u16 = 0;
var dbg_entry_lc: u16 = 0;
pub fn dbgEntry() [4]u32 { return .{ if (dbg_entry_captured) 1 else 0, dbg_entry_bp, dbg_entry_sp, dbg_entry_lc }; }
// Captured param values (slots 1..10) of the watched function on first entry,
// encoded as tag*1e0 + number. We store tag and a numeric snapshot so the
// harness can print them and reproduce the state machine in a Node oracle.
var dbg_entry_ptag: [12]u8 = [_]u8{255} ** 12;
var dbg_entry_pnum: [12]f64 = [_]f64{0} ** 12;
pub fn dbgEntryParamTag(i: usize) u8 { return if (i < 12) dbg_entry_ptag[i] else 255; }
pub fn dbgEntryParamNum(i: usize) f64 { return if (i < 12) dbg_entry_pnum[i] else 0; }
fn captureEntryParams(base: u32) void {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const a = base + i;
        if (a < MAX_STACK and a < sp) {
            dbg_entry_ptag[i] = @intFromEnum(stack[a].tag);
            dbg_entry_pnum[i] = stack[a].toNumber();
        } else { dbg_entry_ptag[i] = 254; dbg_entry_pnum[i] = 0; }
    }
}
// Watch a specific absolute stack address for set_local writes.
pub var dbg_watch_addr: u32 = 0xFFFFFFFF;
var dbg_watch_writes: u32 = 0;
var dbg_watch_last_tag: u8 = 255;
var dbg_watch_last_bp: u16 = 0;
var dbg_watch_last_slot: u16 = 0;
var dbg_watch_last_func: u16 = 0;
var dbg_watch_last_framecount: u16 = 0;
var dbg_watch_last_lc: u16 = 0;
pub fn dbgWatchWrites() u32 { return dbg_watch_writes; }
pub fn dbgWatchLastTag() u8 { return dbg_watch_last_tag; }
pub fn dbgWatchLastBp() u16 { return dbg_watch_last_bp; }
pub fn dbgWatchLastSlot() u16 { return dbg_watch_last_slot; }
pub fn dbgWatchLastFunc() u16 { return dbg_watch_last_func; }
pub fn dbgWatchLastFrameCount() u16 { return dbg_watch_last_framecount; }
pub fn dbgWatchLastLc() u16 { return dbg_watch_last_lc; }
var dbg_undef_prop_captured: bool = false;
var dbg_undef_prop_count: u32 = 0;
pub fn dbgUndefPropCount() u32 { return dbg_undef_prop_count; }
var dbg_undef_prop_name: u32 = 0;
var dbg_undef_prop_recv_name: u32 = 0;
var dbg_undef_prop_func: u16 = 0;
var dbg_undef_prop_ip: usize = 0;
pub fn dbgUndefPropName() []const u8 { return if (dbg_undef_prop_name == 0) "" else values.getString(dbg_undef_prop_name); }
pub fn dbgUndefPropRecvName() []const u8 { return if (dbg_undef_prop_recv_name == 0) "" else values.getString(dbg_undef_prop_recv_name); }
pub fn dbgUndefPropFunc() u16 { return dbg_undef_prop_func; }
pub fn dbgUndefPropIp() usize { return dbg_undef_prop_ip; }
pub fn dbgUndefPropFuncSrc() u32 {
    if (dbg_undef_prop_func == 0xFFFF or dbg_undef_prop_func == 0xFFFE) return 0;
    return compiler.getFunction(dbg_undef_prop_func).src_start;
}
pub fn dbgNcmRecvName() []const u8 { return if (dbg_ncm_recv_name == 0) "" else values.getString(dbg_ncm_recv_name); }
pub fn dbgNcmRingCount() usize { return dbg_ncm_ring_n; }
pub fn dbgNcmRing(i: usize) []const u8 { if (i >= dbg_ncm_ring_n) return ""; return if (dbg_ncm_ring[i] == 0) "" else values.getString(dbg_ncm_ring[i]); }
pub fn dbgResetNcm() void { dbg_ncm_captured = false; dbg_ncm_recv_tag = 255; dbg_ncm_method = 0; dbg_ncm_prop_count = 0; dbg_ncm_method_present = false; dbg_ncm_recv_name = 0; }
pub fn dbgNcmRecvTag() u8 { return dbg_ncm_recv_tag; }
pub fn dbgNcmMethod() []const u8 { return if (dbg_ncm_method == 0) "" else values.getString(dbg_ncm_method); }
pub fn dbgNcmMethodPresent() bool { return dbg_ncm_method_present; }
pub fn dbgNcmPropCount() usize { return dbg_ncm_prop_count; }
pub fn dbgNcmProp(i: usize) []const u8 { if (i >= dbg_ncm_prop_count) return ""; return values.getString(dbg_ncm_props[i]); }

var dbg_last_eval_len: usize = 0;
pub var dbg_bigeval_len: usize = 0;
pub var dbg_bigeval_head: [200]u8 = undefined;
pub var dbg_bigeval_head_len: usize = 0;
pub var dbg_bigeval_full: [65536]u8 = undefined;
pub var dbg_bigeval_full_len: usize = 0;
pub var dbg_eoi_captured: bool = false;
pub var dbg_eoi_src: [8192]u8 = undefined;
pub var dbg_eoi_src_len: usize = 0;
pub var dbg_evsrc_on: bool = false;
pub var dbg_evsrc_len_arr: [8192]u32 = undefined;
pub var dbg_evsrc_hash_arr: [8192]u32 = undefined;
pub var dbg_evsrc_n: usize = 0;
pub fn dbgEvSrcEnable() void { dbg_evsrc_on = true; dbg_evsrc_n = 0; }
pub fn dbgEvSrcN() usize { return dbg_evsrc_n; }
pub fn dbgEvSrcLen(i: usize) u32 { return if (i < dbg_evsrc_n) dbg_evsrc_len_arr[i] else 0; }
pub fn dbgEvSrcHash(i: usize) u32 { return if (i < dbg_evsrc_n) dbg_evsrc_hash_arr[i] else 0; }
pub var dbg_evsrc_cap_idx: usize = 0xFFFFFFFF;
pub var dbg_evsrc_cap_buf: [4096]u8 = undefined;
pub var dbg_evsrc_cap_len: usize = 0;
pub fn dbgEvSrcCapSet(idx: usize) void { dbg_evsrc_cap_idx = idx; dbg_evsrc_cap_len = 0; }
pub fn dbgEvSrcCap() []const u8 { return dbg_evsrc_cap_buf[0..dbg_evsrc_cap_len]; }
pub var dbg_eoi_slen: usize = 0;
pub var dbg_eoi_stopbyte: u32 = 0;
pub var dbg_eoi_stoptok: u8 = 0;
pub fn dbgEoiSrc() []const u8 { return dbg_eoi_src[0..dbg_eoi_src_len]; }
pub fn dbgEoiSlen() usize { return dbg_eoi_slen; }
pub fn dbgEoiStopByte() u32 { return dbg_eoi_stopbyte; }
pub fn dbgEoiStopTok() u8 { return dbg_eoi_stoptok; }
pub var dbg_eoi_func: [12]u16 = [_]u16{0xFFFF} ** 12;
pub var dbg_eoi_ip: [12]u32 = [_]u32{0} ** 12;
pub var dbg_eoi_framen: usize = 0;
pub fn dbgEoiFrameN() usize { return dbg_eoi_framen; }
pub fn dbgEoiFunc(i: usize) u16 { return if (i < dbg_eoi_framen) dbg_eoi_func[i] else 0xFFFF; }
pub fn dbgEoiIp(i: usize) u32 { return if (i < dbg_eoi_framen) dbg_eoi_ip[i] else 0; }
pub var dbg_eoi_bldr_tag: [12]u8 = [_]u8{255} ** 12;
pub var dbg_eoi_bldr_num: [12]f64 = [_]f64{-999999} ** 12;
pub var dbg_eoi_bldr_slen: [12]u32 = [_]u32{0} ** 12;
pub fn dbgEoiBldrTag(i: usize) u8 { return if (i < 12) dbg_eoi_bldr_tag[i] else 255; }
pub fn dbgEoiBldrNum(i: usize) f64 { return if (i < 12) dbg_eoi_bldr_num[i] else -999999; }
pub fn dbgEoiBldrSlen(i: usize) u32 { return if (i < 12) dbg_eoi_bldr_slen[i] else 0; }
pub var dbg_dotstring_captured: bool = false;
pub var dbg_dotstring_src: [4096]u8 = undefined;
pub var dbg_dotstring_src_len: usize = 0;
pub fn dbgDotStringSrc() []const u8 { return dbg_dotstring_src[0..dbg_dotstring_src_len]; }
pub var dbg_targetfn_want: u16 = 0xFFFF;
pub var dbg_targetfn_captured: bool = false;
pub var dbg_targetfn_src: [8192]u8 = undefined;
pub var dbg_targetfn_src_len: usize = 0;
pub var dbg_targetfn_fn_before: u16 = 0;
pub var dbg_targetfn_fn_after: u16 = 0;
pub fn dbgTargetFnSrc() []const u8 { return dbg_targetfn_src[0..dbg_targetfn_src_len]; }
pub fn dbgTargetFnRange() [2]u16 { return .{ dbg_targetfn_fn_before, dbg_targetfn_fn_after }; }
pub var dbg_targetfn_evalcaller: u16 = 0xFFFF;
pub var dbg_targetfn_evalbody: u16 = 0xFFFF;
pub fn dbgTargetFnEvalCaller() u16 { return dbg_targetfn_evalcaller; }
pub fn dbgTargetFnEvalBody() u16 { return dbg_targetfn_evalbody; }
pub var dbg_targetfn_uv0_kind: u8 = 255;
pub var dbg_targetfn_uv0_index: u16 = 0;
pub var dbg_targetfn_uv0_count: u16 = 0;
pub fn dbgTargetFnUv0Kind() u8 { return dbg_targetfn_uv0_kind; }
pub fn dbgTargetFnUv0Index() u16 { return dbg_targetfn_uv0_index; }
pub fn dbgTargetFnUv0Count() u16 { return dbg_targetfn_uv0_count; }
pub var dbg_targetfn_caller_uvname: u32 = 0xFFFFFFFF;
pub var dbg_targetfn_caller_uv_islocal: u8 = 0;
pub var dbg_targetfn_caller_uv_kind: u8 = 255;
pub var dbg_targetfn_caller_uv_index: u16 = 0;
pub var dbg_targetfn_caller_upcount: u16 = 0;
pub var dbg_targetfn_caller_uv_closed: u8 = 0;
pub var dbg_targetfn_caller_uv_valtag: u8 = 255;
pub var dbg_targetfn_global_has: u8 = 0;
pub var dbg_targetfn_global_tag: u8 = 255;
pub fn dbgTargetFnCallerUvName() []const u8 { return if (dbg_targetfn_caller_uvname == 0xFFFFFFFF) "" else values.getString(dbg_targetfn_caller_uvname); }
pub fn dbgTargetFnCallerUvIsLocal() u8 { return dbg_targetfn_caller_uv_islocal; }
pub fn dbgTargetFnCallerUvKind() u8 { return dbg_targetfn_caller_uv_kind; }
pub fn dbgTargetFnCallerUvIndex() u16 { return dbg_targetfn_caller_uv_index; }
pub fn dbgTargetFnCallerUpcount() u16 { return dbg_targetfn_caller_upcount; }
pub fn dbgTargetFnCallerUvClosed() u8 { return dbg_targetfn_caller_uv_closed; }
pub fn dbgTargetFnCallerUvValTag() u8 { return dbg_targetfn_caller_uv_valtag; }
pub fn dbgTargetFnGlobalHas() u8 { return dbg_targetfn_global_has; }
pub fn dbgTargetFnGlobalTag() u8 { return dbg_targetfn_global_tag; }
pub var dbg_crpbytes: [32]u8 = [_]u8{0} ** 32;
pub var dbg_crpbytes_n: usize = 0;
pub var dbg_crpbytes_ip: u32 = 0;
pub var dbg_crpbytes_start: u32 = 0;
pub var dbg_crpbytes_nameidx: u16 = 0;
pub fn dbgCrpBytesN() usize { return dbg_crpbytes_n; }
pub fn dbgCrpByte(i: usize) u8 { return if (i < dbg_crpbytes_n) dbg_crpbytes[i] else 0; }
pub fn dbgCrpBytesStart() u32 { return dbg_crpbytes_start; }
pub fn dbgCrpBytesIp() u32 { return dbg_crpbytes_ip; }
pub fn dbgCrpBytesNameIdx() u16 { return dbg_crpbytes_nameidx; }
pub fn dbgOpNameOf(byte: u8) []const u8 { return @tagName(@as(Op, @enumFromInt(byte))); }
pub var dbg_crpkey: [32]u8 = undefined;
pub var dbg_crpkey_len: usize = 0;
pub var dbg_crpkey_is_elem: bool = false;
pub fn dbgCrpKey() []const u8 { return dbg_crpkey[0..dbg_crpkey_len]; }
pub fn dbgCrpKeyIsElem() bool { return dbg_crpkey_is_elem; }
pub var dbg_crpframe_func: [8]u16 = [_]u16{0} ** 8;
pub var dbg_crpframe_srcstart: [8]u32 = [_]u32{0} ** 8;
pub var dbg_crpframe_ip: [8]u32 = [_]u32{0} ** 8;
pub var dbg_crpframe_n: usize = 0;
pub fn dbgCrpFrameN() usize { return dbg_crpframe_n; }
pub fn dbgCrpFrameFunc(i: usize) u16 { return if (i < dbg_crpframe_n) dbg_crpframe_func[i] else 0; }
pub fn dbgCrpFrameSrcStart(i: usize) u32 { return if (i < dbg_crpframe_n) dbg_crpframe_srcstart[i] else 0; }
pub fn dbgCrpFrameIp(i: usize) u32 { return if (i < dbg_crpframe_n) dbg_crpframe_ip[i] else 0; }
pub var dbg_crpslots_tag: [24]u8 = [_]u8{0} ** 24;
pub var dbg_crpslots_n: usize = 0;
pub var dbg_crpslots_func: u16 = 0;
pub var dbg_crpslots_lc: u16 = 0;
pub var dbg_crpslots_pc: u8 = 0;
pub var dbg_crpslots_bp: u16 = 0;
pub fn dbgCrpSlotsN() usize { return dbg_crpslots_n; }
pub fn dbgCrpSlotTag(i: usize) u8 { return if (i < dbg_crpslots_n) dbg_crpslots_tag[i] else 255; }
pub fn dbgCrpSlotsLc() u16 { return dbg_crpslots_lc; }
pub fn dbgCrpSlotsPc() u8 { return dbg_crpslots_pc; }
pub fn dbgCrpSlotsFunc() u16 { return dbg_crpslots_func; }
pub var dbg_crpupval_tag: [16]u8 = [_]u8{255} ** 16;
pub var dbg_crpupval_islocal: [16]u8 = [_]u8{0} ** 16;
pub var dbg_crpupval_index: [16]u16 = [_]u16{0} ** 16;
pub var dbg_crpupval_funcidx: [16]u16 = [_]u16{0xFFFF} ** 16;
pub fn dbgCrpUpvalFuncIdx(i: usize) u16 { return if (i < dbg_crpupval_n) dbg_crpupval_funcidx[i] else 0xFFFF; }
pub var dbg_crpupval_n: usize = 0;
pub fn dbgCrpUpvalN() usize { return dbg_crpupval_n; }
pub fn dbgCrpUpvalTag(i: usize) u8 { return if (i < dbg_crpupval_n) dbg_crpupval_tag[i] else 255; }
pub fn dbgCrpUpvalIsLocal(i: usize) u8 { return if (i < dbg_crpupval_n) dbg_crpupval_islocal[i] else 0; }
pub fn dbgCrpUpvalIndex(i: usize) u16 { return if (i < dbg_crpupval_n) dbg_crpupval_index[i] else 0; }
pub var dbg_crpu4_upvalcount: u16 = 0;
pub var dbg_crpu4_uv0_tag: u8 = 255;
pub var dbg_crpu4_uv0_closed: u8 = 0;
pub var dbg_crpu4_uv0_addr: u32 = 0;
pub fn dbgCrpU4UpvalCount() u16 { return dbg_crpu4_upvalcount; }
pub fn dbgCrpU4Uv0Tag() u8 { return dbg_crpu4_uv0_tag; }
pub fn dbgCrpU4Uv0Closed() u8 { return dbg_crpu4_uv0_closed; }
pub fn dbgCrpU4Uv0Addr() u32 { return dbg_crpu4_uv0_addr; }
pub var dbg_crplocal_num: [8]f64 = [_]f64{-999999} ** 8;
pub var dbg_crplocal_objidx: [8]u32 = [_]u32{0xFFFFFFFF} ** 8;
pub var dbg_crplocal_n: usize = 0;
pub fn dbgCrpLocalNum(i: usize) f64 { return if (i < dbg_crplocal_n) dbg_crplocal_num[i] else -999999; }
pub fn dbgCrpLocalObjIdx(i: usize) u32 { return if (i < dbg_crplocal_n) dbg_crplocal_objidx[i] else 0xFFFFFFFF; }
pub fn dbgCrpLocalN() usize { return dbg_crplocal_n; }
/// Inspect a register bank: read `bank.Y[reg]` and report the raw cell value's
/// tag (before calling .create()). Returns [Y_tag, cell_tag, cell_is_object].
pub var dbg_bankreg_ytag: u8 = 255;
pub var dbg_bankreg_celltag: u8 = 255;
pub var dbg_bankreg_hasY: u8 = 0;
pub fn dbgInspectBankReg(bank_objidx: u32, reg: u32) void {
    dbg_bankreg_ytag = 255; dbg_bankreg_celltag = 255; dbg_bankreg_hasY = 0;
    dbg_cellprop_n = 0; // reset the cell-prop enumeration for this inspection
    if (bank_objidx == 0xFFFFFFFF) return;
    const y = objects.getProperty(bank_objidx, values.internString("Y"));
    dbg_bankreg_ytag = @intFromEnum(y.tag);
    if (y.tag != .object and y.tag != .array) return;
    dbg_bankreg_hasY = 1;
    const cell = getElemFromValue(y, Value.number(@floatFromInt(reg)));
    dbg_bankreg_celltag = @intFromEnum(cell.tag);
    // Is reg 74 an OWN element of Y, or inherited via prototype (Object.create(x.OI))?
    const yidx = y.data.obj_idx;
    dbg_bankreg_ytype = @intFromEnum(objects.objTypeOf(yidx));
    dbg_bankreg_yproto = objects.getObjectPrototypeIdx(yidx);
    if (objects.objTypeOf(yidx) == .array) {
        dbg_bankreg_own = if (reg < objects.arrayLength(yidx)) 1 else 0;
    } else {
        dbg_bankreg_own = if (objects.hasOwnProperty(yidx, builtins.keyToNameIdx(Value.number(@floatFromInt(reg))))) 1 else 0;
    }
    // If the cell is an object, does IT have own getter/concat, or via proto?
    if (cell.tag == .object or cell.tag == .function) {
        dbg_bankreg_cell_objidx = cell.data.obj_idx;
        dbg_bankreg_cell_upcount = objects.closureUpvalCount(cell.data.obj_idx);
        dbg_bankreg_cell_proto = objects.getObjectPrototypeIdx(cell.data.obj_idx);
        // Walk the cell's [[Prototype]] chain; find which level (if any) has an
        // OWN "prototype" property (the bug: cell.prototype should be undefined).
        const proto_name = values.internString("prototype");
        var cur = cell.data.obj_idx; var lvl: u8 = 0;
        dbg_protochain_level = 255;
        while (cur != objects.NULL_OBJ and lvl < 16) : (lvl += 1) {
            dbg_protochain[lvl] = cur;
            dbg_protochain_type[lvl] = @intFromEnum(objects.objTypeOf(cur));
            if (objects.hasOwnProperty(cur, proto_name) and dbg_protochain_level == 255) dbg_protochain_level = lvl;
            cur = objects.getObjectPrototypeIdx(cur);
        }
        dbg_protochain_n = lvl;
        // Dump the OWN property names of the proto level that has "prototype"
        // (the bug source: x.OI should NOT have a "prototype" own prop).
        if (dbg_protochain_level != 255 and dbg_protochain_level < lvl) {
            const badobj = dbg_protochain[dbg_protochain_level];
            dbg_badproto_obj = badobj;
            dbg_badproto_objtype = @intFromEnum(objects.objTypeOf(badobj));
            dbg_badproto_funcid = objects.closureFuncId(badobj);
            const pv = objects.getProperty(badobj, proto_name);
            dbg_badproto_protoval_tag = @intFromEnum(pv.tag);
            dbg_badproto_propcount = objects.ownPropCount(badobj);
            var bi: u16 = 0;
            dbg_badproto_names_n = 0;
            while (bi < objects.ownPropCount(badobj) and dbg_badproto_names_n < dbg_badproto_names.len) : (bi += 1) {
                dbg_badproto_names[dbg_badproto_names_n] = objects.ownPropNameAt(badobj, bi);
                dbg_badproto_names_n += 1;
            }
        }
        // Enumerate the cell's OWN properties; for each function-valued one,
        // record its name + its closure upval0 value tag (the getter's `g`).
        const cidx = cell.data.obj_idx;
        const pc = objects.ownPropCount(cidx);
        var pi: u16 = 0;
        while (pi < pc and dbg_cellprop_n < dbg_cellprop_name.len) : (pi += 1) {
            const nm = objects.ownPropNameAt(cidx, pi);
            const pv = objects.getProperty(cidx, nm);
            dbg_cellprop_name[dbg_cellprop_n] = nm;
            dbg_cellprop_valtag[dbg_cellprop_n] = @intFromEnum(pv.tag);
            if (pv.tag == .function or pv.tag == .object) {
                const fo = pv.data.obj_idx;
                dbg_cellprop_funcid[dbg_cellprop_n] = objects.closureFuncId(fo);
                dbg_cellprop_upcount[dbg_cellprop_n] = objects.closureUpvalCount(fo);
                if (objects.closureUpvalCount(fo) > 0) {
                    var gv = Value.UNDEFINED;
                    if (objects.isClosureUpvalClosed(fo, 0)) gv = objects.getClosureUpvalClosedVal(fo, 0)
                    else { const a = objects.getClosureUpvalAddr(fo, 0); if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) gv = stack[a]; }
                    dbg_cellprop_g_tag[dbg_cellprop_n] = @intFromEnum(gv.tag);
                } else dbg_cellprop_g_tag[dbg_cellprop_n] = 254;
            } else dbg_cellprop_g_tag[dbg_cellprop_n] = 253;
            dbg_cellprop_n += 1;
        }
    }
}
pub var dbg_cellprop_name: [16]u32 = [_]u32{0} ** 16;
pub var dbg_cellprop_valtag: [16]u8 = [_]u8{255} ** 16;
pub var dbg_cellprop_upcount: [16]u16 = [_]u16{0} ** 16;
pub var dbg_cellprop_g_tag: [16]u8 = [_]u8{255} ** 16;
pub var dbg_cellprop_n: usize = 0;
pub fn dbgCellPropN() usize { return dbg_cellprop_n; }
pub fn dbgCellPropName(i: usize) []const u8 { return if (i < dbg_cellprop_n and dbg_cellprop_name[i] != 0) values.getString(dbg_cellprop_name[i]) else ""; }
pub fn dbgCellPropValTag(i: usize) u8 { return if (i < dbg_cellprop_n) dbg_cellprop_valtag[i] else 255; }
pub fn dbgCellPropUpcount(i: usize) u16 { return if (i < dbg_cellprop_n) dbg_cellprop_upcount[i] else 0; }
pub fn dbgCellPropGTag(i: usize) u8 { return if (i < dbg_cellprop_n) dbg_cellprop_g_tag[i] else 255; }
pub var dbg_cellprop_funcid: [16]u16 = [_]u16{0xFFFF} ** 16;
pub fn dbgCellPropFuncId(i: usize) u16 { return if (i < dbg_cellprop_n) dbg_cellprop_funcid[i] else 0xFFFF; }
// ── Register-trace (differential vs jsdom oracle) ──
pub const dbg_rt_max: usize = 200000;
pub var dbg_rt_on: bool = false;
pub var dbg_rt_multi: bool = false;
pub fn dbgRtMultiEnable() void { dbg_rt_multi = true; dbg_rt_on = false; dbg_rt_n = 0; }
pub var dbg_rt_qfunc: u16 = 0xFFFF;
pub var dbg_rt_wufunc: u16 = 0xFFFF;
pub var dbg_rt_op: [dbg_rt_max]u8 = undefined;
pub var dbg_rt_reg: [dbg_rt_max]i32 = undefined;
pub var dbg_rt_kind: [dbg_rt_max]u8 = undefined;
pub var dbg_rt_val: [dbg_rt_max]f64 = undefined;
pub var dbg_rt_e0: [dbg_rt_max]f64 = undefined;
pub var dbg_rt_e1: [dbg_rt_max]f64 = undefined;
pub var dbg_rt_qret_pending: bool = false;
pub var dbg_rt_qret_idx: usize = 0;
pub var dbg_rt_n: usize = 0;
pub fn dbgRtVal(i: usize) f64 { return if (i < dbg_rt_n) dbg_rt_val[i] else -1234567890123.0; }
pub fn dbgRtE0(i: usize) f64 { return if (i < dbg_rt_n) dbg_rt_e0[i] else -1234567890123.0; }
pub fn dbgRtE1(i: usize) f64 { return if (i < dbg_rt_n) dbg_rt_e1[i] else -1234567890123.0; }
pub const dbg_q363_max: usize = 4000;
pub var dbg_q363_on: bool = false;
pub var dbg_q363_pending: bool = false;
pub var dbg_q363_val: [dbg_q363_max]f64 = undefined;
pub var dbg_q363_tag: [dbg_q363_max]u8 = undefined;
pub var dbg_q363_elems: [dbg_q363_max][4]f64 = undefined;
pub var dbg_q363_obj: [dbg_q363_max]u32 = [_]u32{0xFFFFFFFF} ** dbg_q363_max;
pub fn dbgQ363Obj(i: usize) u32 { return if (i < dbg_q363_n) dbg_q363_obj[i] else 0xFFFFFFFF; }
pub fn dbgQ363Elem(i: usize, j: usize) f64 { return if (i < dbg_q363_n and j < 4) dbg_q363_elems[i][j] else -1234567890123.0; }
pub var dbg_q363_n: usize = 0;
pub fn dbgQ363Enable() void { dbg_q363_on = true; dbg_q363_n = 0; dbg_q363_pending = false; }
pub fn dbgQ363N() usize { return dbg_q363_n; }
pub fn dbgQ363Val(i: usize) f64 { return if (i < dbg_q363_n) dbg_q363_val[i] else -1234567890123.0; }
pub fn dbgQ363Tag(i: usize) u8 { return if (i < dbg_q363_n) dbg_q363_tag[i] else 255; }
pub var dbg_q363_bank_done: bool = false;
pub var dbg_q363_bank_obj: u32 = 0xFFFFFFFF;
pub fn dbgQ363BankObj() u32 { return dbg_q363_bank_obj; }
pub fn dbgRtEnable(qfunc: u16, wufunc: u16) void { dbg_rt_on = true; dbg_rt_qfunc = qfunc; dbg_rt_wufunc = wufunc; dbg_rt_n = 0; }
pub fn dbgRtN() usize { return dbg_rt_n; }
pub fn dbgRtOp(i: usize) u8 { return if (i < dbg_rt_n) dbg_rt_op[i] else 0; }
pub fn dbgRtReg(i: usize) i32 { return if (i < dbg_rt_n) dbg_rt_reg[i] else -1; }
pub fn dbgRtKind(i: usize) u8 { return if (i < dbg_rt_n) dbg_rt_kind[i] else 255; }
// Discovery: (func_id, arg0) for all user calls with numeric arg0.
pub const dbg_rtdisc_max: usize = 20000;
pub var dbg_rtdisc_on: bool = false;
pub var dbg_rtdisc_func: [dbg_rtdisc_max]u16 = undefined;
pub var dbg_rtdisc_reg: [dbg_rtdisc_max]i32 = undefined;
pub var dbg_rtdisc_n: usize = 0;
pub fn dbgRtDiscEnable() void { dbg_rtdisc_on = true; dbg_rtdisc_n = 0; }
pub fn dbgRtDiscN() usize { return dbg_rtdisc_n; }
pub fn dbgRtDiscFunc(i: usize) u16 { return if (i < dbg_rtdisc_n) dbg_rtdisc_func[i] else 0xFFFF; }
pub fn dbgRtDiscReg(i: usize) i32 { return if (i < dbg_rtdisc_n) dbg_rtdisc_reg[i] else -1; }
pub var dbg_rt_capture_at: usize = 0xFFFFFFFF;
pub var dbg_rt_captured: bool = false;
pub var dbg_rt_cap_reg: i32 = -1;
pub var dbg_rt_cap_func: [12]u16 = [_]u16{0xFFFF} ** 12;
pub var dbg_rt_cap_ip: [12]u32 = [_]u32{0} ** 12;
pub var dbg_rt_cap_framen: usize = 0;
pub fn dbgRtSetCaptureAt(n: usize) void { dbg_rt_capture_at = n; dbg_rt_captured = false; }
pub fn dbgRtCapReg() i32 { return dbg_rt_cap_reg; }
pub fn dbgRtCapFrameN() usize { return dbg_rt_cap_framen; }
pub fn dbgRtCapFunc(i: usize) u16 { return if (i < dbg_rt_cap_framen) dbg_rt_cap_func[i] else 0xFFFF; }
pub fn dbgRtCapIp(i: usize) u32 { return if (i < dbg_rt_cap_framen) dbg_rt_cap_ip[i] else 0; }
pub var dbg_wcap_reg: i32 = -1;
pub var dbg_wcap_nth: u32 = 0;
pub var dbg_wcap_seen: u32 = 0;
pub var dbg_wcap_done: bool = false;
pub var dbg_wcap_gtag: u8 = 255;
pub var dbg_wcap_func: [12]u16 = [_]u16{0xFFFF} ** 12;
pub var dbg_wcap_ip: [12]u32 = [_]u32{0} ** 12;
pub var dbg_wcap_framen: usize = 0;
pub fn dbgWCapSet(reg: i32, nth: u32) void { dbg_wcap_reg = reg; dbg_wcap_nth = nth; dbg_wcap_seen = 0; dbg_wcap_done = false; }
pub fn dbgWCapGTag() u8 { return dbg_wcap_gtag; }
pub fn dbgWCapFrameN() usize { return dbg_wcap_framen; }
pub fn dbgWCapFunc(i: usize) u16 { return if (i < dbg_wcap_framen) dbg_wcap_func[i] else 0xFFFF; }
pub fn dbgWCapIp(i: usize) u32 { return if (i < dbg_wcap_framen) dbg_wcap_ip[i] else 0; }
pub var dbg_wcap_caller_num: [8]f64 = [_]f64{-999999} ** 8;
pub var dbg_wcap_caller_tag: [8]u8 = [_]u8{255} ** 8;
pub var dbg_wcap_caller_func: u16 = 0xFFFF;
pub fn dbgWCapCallerNum(i: usize) f64 { return if (i < 8) dbg_wcap_caller_num[i] else -999999; }
pub fn dbgWCapCallerTag(i: usize) u8 { return if (i < 8) dbg_wcap_caller_tag[i] else 255; }
pub fn dbgWCapCallerFunc() u16 { return dbg_wcap_caller_func; }
pub var dbg_wcap_l5_objidx: u32 = 0xFFFFFFFF;
pub var dbg_wcap_l5_type: u8 = 255;
pub var dbg_wcap_l4key: [48]u8 = undefined;
pub var dbg_wcap_l4key_len: usize = 0;
pub var dbg_wcap_l5key_valtag: u8 = 255;
pub var dbg_wcap_l5_hasown: u8 = 0;
pub fn dbgWCapL5ObjIdx() u32 { return dbg_wcap_l5_objidx; }
pub fn dbgWCapL5Type() u8 { return dbg_wcap_l5_type; }
pub fn dbgWCapL4Key() []const u8 { return dbg_wcap_l4key[0..dbg_wcap_l4key_len]; }
pub fn dbgWCapL5KeyValTag() u8 { return dbg_wcap_l5key_valtag; }
pub fn dbgWCapL5HasOwn() u8 { return dbg_wcap_l5_hasown; }
/// Distinct funcs called with arg0==reg, plus their call counts (top one).
/// Returns the SECOND most common func (the writer is usually distinct from the reader).
pub fn dbgRtDiscSecondFuncForReg(reg: i32, exclude: u16) u16 {
    var best_func: u16 = 0xFFFF;
    var best_cnt: u32 = 0;
    var fi: usize = 0;
    while (fi < dbg_rtdisc_n) : (fi += 1) {
        if (dbg_rtdisc_reg[fi] == reg and dbg_rtdisc_func[fi] != exclude) {
            const f = dbg_rtdisc_func[fi];
            var c: u32 = 0; var fj: usize = 0;
            while (fj < dbg_rtdisc_n) : (fj += 1) { if (dbg_rtdisc_reg[fj] == reg and dbg_rtdisc_func[fj] == f) c += 1; }
            if (c > best_cnt) { best_cnt = c; best_func = f; }
        }
    }
    return best_func;
}
/// Histogram of ALL user-function call counts (by func_id) during the run,
/// so we can identify PP (the dominant bit-reader) and other hot funcs.
pub var dbg_callhist: [4096]u32 = [_]u32{0} ** 4096;
pub var dbg_callhist_on: bool = false;
pub fn dbgCallHistEnable() void { dbg_callhist_on = true; }
pub const dbg_pp_max: usize = 200000;
pub var dbg_pp_on: bool = false;
pub var dbg_pp_func: u16 = 0xFFFF;
pub var dbg_pp_ret: [dbg_pp_max]f64 = undefined;
pub var dbg_pp_p_arr: [dbg_pp_max]f64 = undefined;
pub var dbg_pp_g_arr: [dbg_pp_max]f64 = undefined;
pub var dbg_pp_caller_arr: [dbg_pp_max]u16 = undefined;
pub fn dbgPpCallerAt(i: usize) u16 { return if (i < dbg_pp_n) dbg_pp_caller_arr[i] else 0xFFFF; }
pub var dbg_pp_n: usize = 0;
pub fn dbgPpP(i: usize) f64 { return if (i < dbg_pp_n) dbg_pp_p_arr[i] else -1; }
pub fn dbgPpG(i: usize) f64 { return if (i < dbg_pp_n) dbg_pp_g_arr[i] else -1; }
pub fn dbgPpEnable(func: u16) void { dbg_pp_on = true; dbg_pp_func = func; dbg_pp_n = 0; }
pub fn dbgPpN() usize { return dbg_pp_n; }
pub fn dbgPpRet(i: usize) f64 { return if (i < dbg_pp_n) dbg_pp_ret[i] else -1; }
pub var dbg_pp_capture_at: usize = 0xFFFFFFFF;
pub var dbg_pp_cap_done: bool = false;
pub var dbg_pp_cap_p_actual: f64 = -1;
pub var dbg_pp_cap_g_actual: f64 = -1;
pub var dbg_pp_cap_b_actual: u8 = 255;
pub var dbg_pp_cap_ret: f64 = -1;
pub fn dbgPpCapPActual() f64 { return dbg_pp_cap_p_actual; }
pub fn dbgPpCapGActual() f64 { return dbg_pp_cap_g_actual; }
pub fn dbgPpCapBActual() u8 { return dbg_pp_cap_b_actual; }
pub fn dbgPpCapRet() f64 { return dbg_pp_cap_ret; }
pub var dbg_pp_caller_func: u16 = 0xFFFF;
pub var dbg_pp_caller_ip: u32 = 0;
pub var dbg_pp_stack_func: [32]u16 = [_]u16{0xFFFF} ** 32;
pub var dbg_pp_stack_ip: [32]u32 = [_]u32{0} ** 32;
pub var dbg_pp_stack_n: usize = 0;
pub var dbg_pp_disp_func: u16 = 0xFFFF;
pub var dbg_pp_disp_ip: u32 = 0;
pub var dbg_pp_disp_num: [16]f64 = [_]f64{-999999} ** 16;
pub var dbg_pp_disp_tag: [16]u8 = [_]u8{255} ** 16;
pub fn dbgPpDispFunc() u16 { return dbg_pp_disp_func; }
pub fn dbgPpDispIp() u32 { return dbg_pp_disp_ip; }
pub fn dbgPpDispNum(i: usize) f64 { return if (i < 16) dbg_pp_disp_num[i] else -999999; }
pub fn dbgPpDispTag(i: usize) u8 { return if (i < 16) dbg_pp_disp_tag[i] else 255; }
pub var dbg_pp_sm_func: u16 = 0xFFFF;
pub var dbg_pp_sm_num: [16]f64 = [_]f64{-999999} ** 16;
pub var dbg_pp_sm_tag: [16]u8 = [_]u8{255} ** 16;
pub fn dbgPpSmFunc() u16 { return dbg_pp_sm_func; }
pub fn dbgPpSmNum(i: usize) f64 { return if (i < 16) dbg_pp_sm_num[i] else -999999; }
pub fn dbgPpSmTag(i: usize) u8 { return if (i < 16) dbg_pp_sm_tag[i] else 255; }
pub fn dbgPpStackN() usize { return dbg_pp_stack_n; }
pub fn dbgPpStackFunc(i: usize) u16 { return if (i < 32) dbg_pp_stack_func[i] else 0xFFFF; }
pub fn dbgPpStackIp(i: usize) u32 { return if (i < 32) dbg_pp_stack_ip[i] else 0; }
pub var dbg_pp_caller_num: [16]f64 = [_]f64{-999999} ** 16;
pub fn dbgPpCallerFunc() u16 { return dbg_pp_caller_func; }
pub fn dbgPpCallerIp() u32 { return dbg_pp_caller_ip; }
pub fn dbgPpCallerNum(i: usize) f64 { return if (i < 16) dbg_pp_caller_num[i] else -999999; }
pub var dbg_pp_cap_b_tag: u8 = 255;
pub var dbg_pp_cap_b_num: f64 = -1;
pub var dbg_pp_cap_g_num: f64 = -1;
pub var dbg_pp_cap_xv: f64 = -1;
pub var dbg_pp_cap_xB: f64 = -999999;
pub var dbg_pp_cap_xO: f64 = -999999;
pub fn dbgPpCapXB() f64 { return dbg_pp_cap_xB; }
pub fn dbgPpCapXO() f64 { return dbg_pp_cap_xO; }
pub var dbg_pp_cap_xF: u8 = 255;
pub var dbg_pp_cap_xI: f64 = -999999;
pub var dbg_pp_cap_xAP: u8 = 255;
pub fn dbgPpCapXF() u8 { return dbg_pp_cap_xF; }
pub fn dbgPpCapXI() f64 { return dbg_pp_cap_xI; }
pub fn dbgPpCapXAP() u8 { return dbg_pp_cap_xAP; }
pub var dbg_pp_cap_wo_tag: u8 = 255;
pub var dbg_pp_cap_wo_len: u32 = 0;
pub var dbg_pp_cap_pos: u32 = 26644;
pub fn dbgPpSetCapPos(p: u32) void { dbg_pp_cap_pos = p; }
pub fn dbgPpSetCaptureAt(n: usize) void { dbg_pp_capture_at = n; dbg_pp_cap_done = false; dbg_pp_entry_done = false; dbg_pp_entry_n = 0; }
pub var dbg_pp_entry_n: usize = 0;
pub var dbg_pp_entry_done: bool = false;
pub var dbg_pp_e_b_tag: u8 = 255;
pub var dbg_pp_e_b_num: f64 = -1;
pub var dbg_pp_e_g_num: f64 = -1;
pub var dbg_pp_e_argc: u8 = 0;
pub fn dbgPpEBTag() u8 { return dbg_pp_e_b_tag; }
pub fn dbgPpEBNum() f64 { return dbg_pp_e_b_num; }
pub fn dbgPpEGNum() f64 { return dbg_pp_e_g_num; }
pub fn dbgPpEArgc() u8 { return dbg_pp_e_argc; }
pub fn dbgPpCapBTag() u8 { return dbg_pp_cap_b_tag; }
pub fn dbgPpCapBNum() f64 { return dbg_pp_cap_b_num; }
pub fn dbgPpCapGNum() f64 { return dbg_pp_cap_g_num; }
pub fn dbgPpCapXv() f64 { return dbg_pp_cap_xv; }
pub fn dbgPpCapWoTag() u8 { return dbg_pp_cap_wo_tag; }
pub fn dbgPpCapWoLen() u32 { return dbg_pp_cap_wo_len; }
pub var dbg_pp_cap_wo_sample: [8]f64 = [_]f64{-1} ** 8;
pub var dbg_pp_cap_wo_sample2: [8]f64 = [_]f64{-1} ** 8;
pub var dbg_pp_cap_wo_objtype: u8 = 255;
pub fn dbgPpCapWoSample(i: usize) f64 { return if (i < 8) dbg_pp_cap_wo_sample[i] else -1; }
pub fn dbgPpCapWoSample2(i: usize) f64 { return if (i < 8) dbg_pp_cap_wo_sample2[i] else -1; }
pub fn dbgPpCapWoObjType() u8 { return dbg_pp_cap_wo_objtype; }
pub var dbg_pp_cap_ip_len: u32 = 0xFFFFFFFF;
pub var dbg_pp_cap_yt_len: u32 = 0xFFFFFFFF;
pub var dbg_pp_cap_yt_sample: [8]f64 = [_]f64{-1} ** 8;
pub var dbg_pp_r166_len: u32 = 0xFFFFFFFF;
pub var dbg_pp_r169_len: u32 = 0xFFFFFFFF;
pub fn dbgPpR166Len() u32 { return dbg_pp_r166_len; }
pub fn dbgPpR169Len() u32 { return dbg_pp_r169_len; }
pub fn dbgPpCapIpLen() u32 { return dbg_pp_cap_ip_len; }
pub fn dbgPpCapYtLen() u32 { return dbg_pp_cap_yt_len; }
pub fn dbgPpCapYtSample(i: usize) f64 { return if (i < 8) dbg_pp_cap_yt_sample[i] else -1; }
pub var dbg_ppdisc_on: bool = false;
pub var dbg_ppdisc_hist: [4096]u32 = [_]u32{0} ** 4096;
pub fn dbgPpDiscEnable() void { dbg_ppdisc_on = true; }
pub fn dbgPpDiscTop() u16 {
    var best: u32 = 0; var besti: u16 = 0xFFFF; var i: usize = 0;
    while (i < dbg_ppdisc_hist.len) : (i += 1) { if (dbg_ppdisc_hist[i] > best) { best = dbg_ppdisc_hist[i]; besti = @intCast(i); } }
    return besti;
}
pub fn dbgPpDiscCount(fid: u16) u32 { return if (fid < dbg_ppdisc_hist.len) dbg_ppdisc_hist[fid] else 0; }
pub fn dbgCallHistTop(out_id: *[16]u16, out_cnt: *[16]u32) void {
    var used: [4096]bool = [_]bool{false} ** 4096;
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        var best: u32 = 0; var besti: usize = 0xFFFF;
        var i: usize = 0;
        while (i < dbg_callhist.len) : (i += 1) {
            if (!used[i] and dbg_callhist[i] > best) { best = dbg_callhist[i]; besti = i; }
        }
        if (besti == 0xFFFF) { out_id[k] = 0xFFFF; out_cnt[k] = 0; } else { out_id[k] = @intCast(besti); out_cnt[k] = best; used[besti] = true; }
    }
}
/// Count how many times func_id was called with arg0 == reg184.
pub fn dbgRtDiscCountFuncReadingReg(reg: i32) u16 {
    // Find the func that most often has arg0==reg; return that func id.
    var best_func: u16 = 0xFFFF;
    var best_cnt: u32 = 0;
    var fi: usize = 0;
    while (fi < dbg_rtdisc_n) : (fi += 1) {
        if (dbg_rtdisc_reg[fi] == reg) {
            const f = dbg_rtdisc_func[fi];
            var c: u32 = 0;
            var fj: usize = 0;
            while (fj < dbg_rtdisc_n) : (fj += 1) { if (dbg_rtdisc_reg[fj] == reg and dbg_rtdisc_func[fj] == f) c += 1; }
            if (c > best_cnt) { best_cnt = c; best_func = f; }
        }
    }
    return best_func;
}
/// Kind mapping matching the jsdom oracle's __kind():
/// 0=undef,1=null,2=bool,3=number,4=string,5=object,6=function,7=array.
fn dbgKindOf(v: Value) u8 {
    return switch (v.tag) {
        .undefined => 0,
        .null_val => 1,
        .boolean => 2,
        .number => 3,
        .string => 4,
        .function => 6,
        .array => 7,
        // Arrays are stored with tag=.object + objType=.array in this VM, so
        // classify by the internal object type to match jsdom's Array.isArray.
        .object => if (objects.objTypeOf(v.data.obj_idx) == .array) 7 else 5,
        .symbol => 5,
    };
}
pub var dbg_bankreg_ytype: u8 = 255;
pub var dbg_bankreg_yproto: u32 = 0;
pub var dbg_bankreg_own: u8 = 0;
pub var dbg_bankreg_cell_objidx: u32 = 0xFFFFFFFF;
pub var dbg_bankreg_cell_upcount: u16 = 0;
pub var dbg_bankreg_cell_proto: u32 = 0;
pub fn dbgBankRegYType() u8 { return dbg_bankreg_ytype; }
pub fn dbgBankRegYProto() u32 { return dbg_bankreg_yproto; }
pub fn dbgBankRegOwn() u8 { return dbg_bankreg_own; }
pub fn dbgBankRegCellObjIdx() u32 { return dbg_bankreg_cell_objidx; }
pub fn dbgBankRegCellUpcount() u16 { return dbg_bankreg_cell_upcount; }
pub fn dbgBankRegCellProto() u32 { return dbg_bankreg_cell_proto; }
pub var dbg_protochain: [16]u32 = [_]u32{0} ** 16;
pub var dbg_protochain_type: [16]u8 = [_]u8{255} ** 16;
pub var dbg_protochain_n: u8 = 0;
pub var dbg_protochain_level: u8 = 255;
pub fn dbgProtoChainN() u8 { return dbg_protochain_n; }
pub fn dbgProtoChain(i: usize) u32 { return if (i < 16) dbg_protochain[i] else 0; }
pub fn dbgProtoChainType(i: usize) u8 { return if (i < 16) dbg_protochain_type[i] else 255; }
pub fn dbgProtoChainProtoLevel() u8 { return dbg_protochain_level; }
pub var dbg_badproto_obj: u32 = 0;
pub var dbg_badproto_objtype: u8 = 255;
pub var dbg_badproto_funcid: u16 = 0xFFFF;
pub var dbg_badproto_protoval_tag: u8 = 255;
pub var dbg_badproto_propcount: u16 = 0;
pub var dbg_badproto_names: [24]u32 = [_]u32{0} ** 24;
pub var dbg_badproto_names_n: usize = 0;
pub fn dbgBadProtoObj() u32 { return dbg_badproto_obj; }
pub fn dbgBadProtoObjType() u8 { return dbg_badproto_objtype; }
pub fn dbgBadProtoFuncId() u16 { return dbg_badproto_funcid; }
pub fn dbgBadProtoValTag() u8 { return dbg_badproto_protoval_tag; }
pub fn dbgBadProtoPropCount() u16 { return dbg_badproto_propcount; }
pub fn dbgBadProtoNameN() usize { return dbg_badproto_names_n; }
pub fn dbgBadProtoName(i: usize) []const u8 { return if (i < dbg_badproto_names_n and dbg_badproto_names[i] != 0) values.getString(dbg_badproto_names[i]) else ""; }
pub fn dbgBankRegYTag() u8 { return dbg_bankreg_ytag; }
pub fn dbgBankRegCellTag() u8 { return dbg_bankreg_celltag; }
pub fn dbgBankRegHasY() u8 { return dbg_bankreg_hasY; }
pub var dbg_reg74_target: u32 = 74;
pub var dbg_reg74_last_cell: u32 = 0xFFFFFFFF;
pub fn dbgReg74LastCell() u32 { return dbg_reg74_last_cell; }
pub var dbg_reg74_valtag: [16]u8 = [_]u8{255} ** 16;
pub var dbg_reg74_bankobj: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_reg74_func: [16]u16 = [_]u16{0xFFFF} ** 16;
pub var dbg_reg74_ip: [16]u32 = [_]u32{0} ** 16;
pub var dbg_reg74_cell_upcount: [16]u16 = [_]u16{0} ** 16;
pub var dbg_reg74_cell_g_tag: [16]u8 = [_]u8{255} ** 16;
pub var dbg_reg74_n: usize = 0;
pub fn dbgReg74N() usize { return dbg_reg74_n; }
pub fn dbgReg74ValTag(i: usize) u8 { return if (i < dbg_reg74_n) dbg_reg74_valtag[i] else 255; }
pub fn dbgReg74BankObj(i: usize) u32 { return if (i < dbg_reg74_n) dbg_reg74_bankobj[i] else 0xFFFFFFFF; }
pub fn dbgReg74Func(i: usize) u16 { return if (i < dbg_reg74_n) dbg_reg74_func[i] else 0xFFFF; }
pub fn dbgReg74Ip(i: usize) u32 { return if (i < dbg_reg74_n) dbg_reg74_ip[i] else 0; }
pub fn dbgReg74CellUpcount(i: usize) u16 { return if (i < dbg_reg74_n) dbg_reg74_cell_upcount[i] else 0; }
pub fn dbgReg74CellGTag(i: usize) u8 { return if (i < dbg_reg74_n) dbg_reg74_cell_g_tag[i] else 255; }
/// Real source position of the throwing IP, resolved via the bytecode->src map
/// (more reliable than FuncDesc.src_start for eval-built functions).
pub fn dbgCrpRealSrcPos() u32 { return compiler.srcPosForBc(dbg_crpbytes_ip); }
pub fn dbgCrpCodeStart() u32 { return compiler.getFunction(dbg_crpslots_func).code_start; }
pub fn dbgCrpCodeLen() u32 { return compiler.getFunction(dbg_crpslots_func).code_len; }
/// Disassemble the throwing function's whole body into a text buffer.
pub var dbg_disasm_buf: [262144]u8 = undefined;
pub var dbg_disasm_len: usize = 0;
pub fn dbgDisasmFunc(func_id: u16) []const u8 {
    dbg_disasm_len = 0;
    const code = compiler.getBytecode();
    const fd = compiler.getFunction(func_id);
    var ip: u32 = fd.code_start;
    const end: u32 = fd.code_start + fd.code_len;
    // Op is enum(u8); the last opcode is `dup2`. Use it as the inclusive upper bound.
    const max_op: u16 = @as(u16, @intFromEnum(Op.dup2)) + 1;
    while (ip < end and ip < code.len) {
        const raw = code[ip];
        if (raw >= max_op) {
            // Invalid opcode byte: record raw and advance 1 (misaligned decode).
            appendNum(ip); appendByte(':'); appendByte('?'); appendNum(raw); appendByte('\n');
            ip += 1;
            continue;
        }
        const op: Op = @enumFromInt(raw);
        const w = operandWidth(op);
        appendDisasm(ip, op, code, w);
        ip += 1 + w;
    }
    return dbg_disasm_buf[0..dbg_disasm_len];
}
/// Find which function owns the global bytecode offset `target_ip`, and disassemble
/// a window of that function centered near target_ip. Also records the owning func id.
pub var dbg_disasm_owner_func: u16 = 0xFFFF;
pub fn dbgDisasmAtIp(target_ip: u32) []const u8 {
    dbg_disasm_len = 0;
    const code = compiler.getBytecode();
    const nfns = compiler.functionCount();
    // Find owning function: the one whose [code_start, code_start+code_len) contains target_ip.
    var owner: u16 = 0xFFFF;
    var fi: u16 = 0;
    while (fi < nfns) : (fi += 1) {
        const fd = compiler.getFunction(fi);
        if (target_ip >= fd.code_start and target_ip < fd.code_start + fd.code_len) { owner = fi; break; }
    }
    dbg_disasm_owner_func = owner;
    if (owner == 0xFFFF) {
        // No owning function; emit a raw note.
        appendByte('n'); appendByte('o'); appendByte('f'); appendByte('n'); appendByte('@');
        appendNum(target_ip); appendByte('\n');
        return dbg_disasm_buf[0..dbg_disasm_len];
    }
    const fd = compiler.getFunction(owner);
    appendByte('f'); appendByte('n'); appendNum(owner);
    appendByte(' '); appendByte('s'); appendByte('t'); appendByte('a'); appendByte('r'); appendByte('t'); appendByte('=');
    appendNum(fd.code_start); appendByte(' '); appendByte('l'); appendByte('e'); appendByte('n'); appendByte('=');
    appendNum(fd.code_len); appendByte(' '); appendByte('t'); appendByte('g'); appendByte('t'); appendByte('=');
    appendNum(target_ip); appendByte('\n');
    // Disassemble a WINDOW around target_ip. To keep alignment we must decode
    // from a known instruction boundary; walk from code_start but only START
    // EMITTING once we're within `window` bytes before target_ip (so a huge
    // function's early body doesn't overflow the buffer before we reach target).
    const window: u32 = 60;
    const emit_from: u32 = if (target_ip > fd.code_start + window) target_ip - window else fd.code_start;
    var ip: u32 = fd.code_start;
    const end: u32 = fd.code_start + fd.code_len;
    const max_op: u16 = @as(u16, @intFromEnum(Op.dup2)) + 1;
    while (ip < end and ip < code.len) {
        const raw = code[ip];
        if (raw >= max_op) {
            if (ip >= emit_from) { appendNum(ip); appendByte(':'); appendByte('?'); appendNum(raw); appendByte('\n'); }
            ip += 1;
            continue;
        }
        const op: Op = @enumFromInt(raw);
        const w = operandWidth(op);
        if (ip >= emit_from) {
            if (ip == target_ip) { appendByte('>'); appendByte('>'); appendByte(' '); }
            appendDisasm(ip, op, code, w);
        }
        ip += 1 + w;
        if (ip > target_ip + 40) break;
    }
    return dbg_disasm_buf[0..dbg_disasm_len];
}
fn appendDisasm(ip: u32, op: Op, code: []const u8, w: u32) void {
    // "ip:opname operand\n"
    appendNum(ip); appendByte(':');
    const nm = @tagName(op);
    for (nm) |c| appendByte(c);
    if (w == 1 and ip + 1 < code.len) { appendByte(' '); appendNum(code[ip + 1]); }
    if (w == 2 and ip + 2 < code.len) { appendByte(' '); appendNum(@as(u32, code[ip + 1]) | (@as(u32, code[ip + 2]) << 8)); }
    appendByte('\n');
}
fn operandWidth(op: Op) u32 {
    return switch (op) {
        // u16 operand (2 bytes)
        .load_const, .get_local, .set_local, .get_upval, .set_upval,
        .get_global, .get_global_safe, .set_global, .def_global,
        .get_prop, .set_prop, .get_optional, .get_elem_optional,
        .make_array, .make_func, .del_prop, .close_scope => 2,
        // u8 operand (1 byte): argc / prop_count
        .call, .call_direct_eval, .call_method, .make_object, .new_call, .define_literal_property => 1,
        // u32 operand (4 bytes): jump targets / offsets
        .jump, .jump_if_false, .jump_if_true, .jump_nullish, .loop_back, .iter_next, .enter_finally => 4,
        // catch, finally, protected-region end
        .enter_try => 12,
        else => 0,
    };
}
fn appendByte(c: u8) void { if (dbg_disasm_len < dbg_disasm_buf.len) { dbg_disasm_buf[dbg_disasm_len] = c; dbg_disasm_len += 1; } }
fn appendNum(v: u32) void {
    if (v == 0) { appendByte('0'); return; }
    var tmp: [10]u8 = undefined; var ti: usize = 0; var x = v;
    while (x > 0) { tmp[ti] = @intCast('0' + (x % 10)); x /= 10; ti += 1; }
    while (ti > 0) { ti -= 1; appendByte(tmp[ti]); }
}
/// Return a window of the persisted big-eval source starting at `off`, up to `len` bytes.
pub fn dbgBigEvalWindow(off: u32, len: u32) []const u8 {
    if (off >= dbg_bigeval_full_len) return "";
    const end = @min(dbg_bigeval_full_len, off + len);
    return dbg_bigeval_full[off..end];
}
pub fn dbgBigEvalFullLen() usize { return dbg_bigeval_full_len; }
pub var dbg_bigeval_has_var: bool = false;
pub var dbg_bigeval_weq: u32 = 0;
pub var dbg_bigeval_is_now: bool = false;
pub var dbg_bigeval_tokens: u32 = 0;
pub var dbg_bigeval_tokpos: u32 = 0;
pub var dbg_bigeval_nodes: u32 = 0;
pub var dbg_bigeval_parse_err: bool = false;
pub var dbg_bigeval_root_null: bool = false;
pub fn dbgBigEvalHead() []const u8 { return dbg_bigeval_head[0..dbg_bigeval_head_len]; }
var dbg_eval_parse_err: bool = false;
var dbg_eval_compile_err: bool = false;
var dbg_eval_nodes: u32 = 0;
var dbg_eval_tokens: u32 = 0;
var dbg_eval_tokpos: u32 = 0;

var dbg_eval_stoptok: u8 = 0;
var dbg_eval_stopbyte: u32 = 0;

pub fn dbgEvalTokens() [2]u32 { return .{ dbg_eval_tokens, dbg_eval_tokpos }; }
pub fn dbgEvalStop() [2]u32 { return .{ dbg_eval_stoptok, dbg_eval_stopbyte }; }
pub fn dbgEval() [2]u32 { return .{ dbg_eval_calls, dbg_eval_compiled }; }
pub fn dbgLastEvalLen() usize { return dbg_last_eval_len; }
pub fn dbgEvalErrors() [3]u32 { return .{ if (dbg_eval_parse_err) 1 else 0, if (dbg_eval_compile_err) 1 else 0, dbg_eval_nodes }; }
/// Expose the eval scratch buffer contents (last eval source) for inspection.
pub fn dbgEvalSource() []const u8 { return eval_src_buf[0..dbg_last_eval_len]; }
pub fn dbgCalls() [3]u32 { return .{ dbg_user_calls, dbg_native_calls, dbg_notcallable }; }

/// Number of distinct not-callable names recorded.
pub fn dbgNotCallableCount() usize { return nc_name_count; }
/// Get the i-th not-callable name (string pool bytes).
pub fn dbgNotCallableName(i: usize) []const u8 {
    if (i >= nc_name_count) return "";
    return values.getString(nc_names[i]);
}

pub fn dbgResetNotCallable() void { nc_name_count = 0; dbg_notcallable = 0; }

fn recordNotCallable(name_idx: u32) void {
    for (0..nc_name_count) |i| if (nc_names[i] == name_idx) return; // dedupe
    if (nc_name_count < MAX_NC_NAMES) { nc_names[nc_name_count] = name_idx; nc_name_count += 1; }
}

/// Get a human-readable reason for the last runtime error (debug).
pub fn getErrorReason() []const u8 {
    return error_reason;
}

/// Debug counters (enter_try executions, throw executions).
pub fn dbgCounters() [2]u32 {
    return .{ dbg_enter_try, dbg_throw };
}

fn fail(reason: []const u8) void {
    dbgTraceFailure(values.internString(reason));
    had_error = true;
    error_reason = reason;
}

// ── Public API ──

/// Execute bytecode. Returns the final value on stack (or undefined).
var realm_generation: u32 = 0;
pub fn realmGeneration() u32 { return realm_generation; }

pub fn execute() Value {
    realm_generation +%= 1;
    dbg_T_name_idx = values.internString("T");
    dbg_Y_name_idx = values.internString("Y");
    dbg_ox_name_idx = values.internString("ox");
    objects.dbg_resolveset_create_idx = values.internString("create");
    dbg_rD_name_idx = values.internString("rD");
    dbg_S_name_idx = values.internString("S");
    dbg_length_name_idx = values.internString("length");
    // Reset VM state
    sp = 0;
    frame_count = 0;
    try_count = 0;
    iter_count = 0;
    for (0..MAX_FRAMES) |i| ctor_is[i] = false;
    had_error = false;
    operation_aborted = false;
    error_value = Value.UNDEFINED;
    finally_count = 0;
    staged_completion = null;
    dbg_finally_unwind = 0;
    dbg_throwmsg_n = 0;
    dbg_firstpropthrow_captured = false;
    dbg_fpt_op_n = 0;
    dbg_firstpropthrow_name = 0;
    dbg_firstpropthrow_recv = 0;
    dbg_fpt_l0 = 0;
    dbg_fpt_l1 = 0;
    dbg_fpt_l2 = 0;
    dbg_fpt_l3 = 0;
    dbg_fpt_l4 = 0;
    dbg_fpt_l5 = 0;
    error_reason = "";
    completion = Value.UNDEFINED;
    dbg_trayride_setprop_count = 0;
    dbg_trayride_target_tag = 255;
    dbg_trayride_target_obj = 0xFFFF;
    dbg_trayride_set_nameidx = 0xFFFFFFFF;
    dbg_trayride_val_tag = 255;
    dbg_enter_try = 0;
    dbg_bigeval_len = 0;
    dbg_bigeval_head_len = 0;
    dbg_bigeval_weq = 0;
    dbg_throw = 0;
    dbg_first_throw_tag = 255;
    dbg_first_throw_num = -1;
    dbg_first_throw_e0 = -9;
    dbg_first_throw_e1 = -9;
    dbg_eval_calls = 0;
    dbg_eval_compiled = 0;
    dbg_user_calls = 0;
    dbg_native_calls = 0;
    dbg_notcallable = 0;
    last_lookup_name = 0;
    prev_lookup_name = 0;
    lookup_ring = [_]u32{0} ** 12;
    lookup_ring_pos = 0;
    op_ring_pos = 0;
    nc_name_count = 0;
    dbg_recvprov_captured = false;
    dbg_recvprov_op = 255;
    dbg_recvprov_upval_idx = 0xFFFF;
    dbg_recvprov_upval_closed = false;
    dbg_recvprov_closure = 0xFFFF;
    dbg_recvprov_upval_count = 0;
    dbg_watch_writes = 0;
    dbg_watch_last_tag = 255;
    dbg_overlap_detected = false;
    dbg_mkuv_captured = false;
    dbg_entry_captured = false;
    dbg_close143 = 0;
    dbg_wcorrupt_detected = false;
    dbg_slotwatch_137_writes = 0;
    dbg_slotwatch_maxslot = 0;
    dbg_slotwatch_137_tag = 255;
    dbg_slotwatch_137_bp = 0;
    dbg_slotwatch_137_ip = 0;
    dbg_s137_op_n = 0;
    dbg_s137_l0 = 0;
    dbg_s137_l1 = 0;
    dbg_s137_l2 = 0;
    dbg_recvprov_slot = 0xFFFF;
    dbg_recvprov_upval_addr = 0;
    dbg_recvprov_addr_tag = 255;
    dbg_recvprov_cur_bp = 0;
    dbg_recvprov_cur_sp = 0;
    dbg_recvprov_ud_islocal = false;
    dbg_recvprov_ud_index = 0;
    dbg_recvprov_owner_func = 0xFFFF;
    dbg_recvprov_owner_bp = 0;
    dbg_recvprov_owner_lc = 0;
    dbg_undef_prop_captured = false;
    dbg_undef_prop_count = 0;
    dbg_undef_prop_name = 0;
    dbg_undef_prop_recv_name = 0;
    dbg_undef_prop_func = 0;
    dbg_undef_prop_ip = 0;
    dbgResetNcm();
    builtins.taskQueueReset();

    // Initialize global object with builtins and browser environment stubs.
    objects.reset();
    objects.bindRuntimeStack(stack[0..]);
    global_obj = objects.createObject();
    builtins.invoke_callback = &invokeBuiltinCallback;
    builtins.callback_aborted = &callbackAborted;
    values.object_number = &numericObjectPrimitive;
    builtins.string_conversion = &stringObjectPrimitive;
    builtins.installGlobals(global_obj);
    env.installEnvironment(global_obj);

    // Push initial frame for top-level code
    frames[0] = .{ .func_id = 0xFFFF, .ip = 0, .bp = 0 };
    frame_count = 1;
    // Catch and block bindings also need storage in the script frame. Keep
    // operands above their peak slot so expressions cannot overwrite them.
    sp = compiler.mainLocalCount();
    @memset(stack[0..sp], Value.UNDEFINED);

    // Run
    return run();
}

/// Check if execution had a runtime error.
pub fn hasError() bool {
    return had_error;
}

/// Get the error value.
pub fn getError() Value {
    return error_value;
}

/// Get the eval completion register (debug).
pub fn getCompletion() Value {
    return completion;
}

/// Read a global variable by name from the current global object.
pub fn getGlobalVar(name: []const u8) Value {
    const idx = values.internString(name);
    return objects.getProperty(global_obj, idx);
}

/// Get the global object index.
pub fn getGlobal() u32 {
    return global_obj;
}

// ── Main Execution Loop ──

// When true, invoking a non-callable value raises a JS TypeError (spec-correct).
// Left off by default until the remaining non-callable divergences in the
// BotGuard success path are resolved (throwing there currently aborts init).
pub var dbg_throw_not_callable: bool = false;

// ── Fingerprint-probe capture ──
// When armed, records the NAMES of properties BotGuard read on environment
// objects (navigator/document/window/screen/location/canvas/webgl) that our env
// did not implement (returned undefined). Each such miss is a fingerprint leak
// that can make Google's server withhold the real integrity token.
pub var dbg_fp_probe: bool = false;
pub var dbg_fp_miss_names: [256]u32 = [_]u32{0} ** 256; // interned name idx
pub var dbg_fp_miss_obj: [256]u32 = [_]u32{0} ** 256;   // env obj idx
pub var dbg_fp_miss_n: usize = 0;
fn recordFpMiss(oi: u32, name_idx: u32) void {
    // Dedup by (obj,name).
    var i: usize = 0;
    while (i < dbg_fp_miss_n) : (i += 1) {
        if (dbg_fp_miss_names[i] == name_idx and dbg_fp_miss_obj[i] == oi) return;
    }
    if (dbg_fp_miss_n < dbg_fp_miss_names.len) {
        dbg_fp_miss_names[dbg_fp_miss_n] = name_idx;
        dbg_fp_miss_obj[dbg_fp_miss_n] = oi;
        dbg_fp_miss_n += 1;
    }
}
pub fn dbgFpMissCount() usize { return dbg_fp_miss_n; }
pub fn dbgFpMissName(i: usize) []const u8 {
    if (i >= dbg_fp_miss_n) return "";
    return values.getString(dbg_fp_miss_names[i]);
}
pub fn dbgFpMissObj(i: usize) u32 {
    if (i >= dbg_fp_miss_n) return 0xFFFFFFFF;
    return dbg_fp_miss_obj[i];
}

// Debug: record when a METHOD-name property read resolves to a non-function
// (the direct cause of "X.method is not a function" throws that inflate the
// payload). Captures (name, resolved-tag, receiver obj_idx, is_env).
pub var dbg_mm_probe: bool = false;
pub var dbg_mm_name: [128]u32 = [_]u32{0} ** 128;
pub var dbg_mm_tag: [128]u8 = [_]u8{0} ** 128;
pub var dbg_mm_isenv: [128]u8 = [_]u8{0} ** 128;
pub var dbg_mm_n: usize = 0;
fn recordMethodMiss(name_idx: u32, tag: u8, is_env: bool) void {
    var i: usize = 0;
    while (i < dbg_mm_n) : (i += 1) if (dbg_mm_name[i] == name_idx and dbg_mm_tag[i] == tag) return;
    if (dbg_mm_n < dbg_mm_name.len) {
        dbg_mm_name[dbg_mm_n] = name_idx;
        dbg_mm_tag[dbg_mm_n] = tag;
        dbg_mm_isenv[dbg_mm_n] = if (is_env) 1 else 0;
        dbg_mm_n += 1;
    }
}
pub fn dbgMmCount() usize { return dbg_mm_n; }
pub fn dbgMmName(i: usize) []const u8 { if (i >= dbg_mm_n) return ""; return values.getString(dbg_mm_name[i]); }
pub fn dbgMmTag(i: usize) u8 { if (i >= dbg_mm_n) return 255; return dbg_mm_tag[i]; }
pub fn dbgMmIsEnv(i: usize) bool { if (i >= dbg_mm_n) return false; return dbg_mm_isenv[i] == 1; }
pub var dbg_applyarr_len: [8]u32 = [_]u32{0} ** 8;
pub var dbg_applyarr_e0: [8]u8 = [_]u8{0} ** 8;
pub var dbg_applyarr_e1: [8]u8 = [_]u8{0} ** 8;
pub var dbg_applyarr_e0type: [8]u8 = [_]u8{255} ** 8;
pub var dbg_applyarr_e0prop: [8][3]u32 = [_][3]u32{[_]u32{0} ** 3} ** 8;
pub var dbg_applyarr_n: usize = 0;
pub var dbg_applyseq_tag: [32]u8 = [_]u8{0} ** 32; // 6=function, 100+objtype=non-fn
pub var dbg_applyseq_n: usize = 0;
pub fn dbgApplySeqCount() usize { return dbg_applyseq_n; }
pub fn dbgApplySeqTag(i: usize) u8 { if (i >= dbg_applyseq_n) return 255; return dbg_applyseq_tag[i]; }
pub fn dbgApplyArrCount() usize { return dbg_applyarr_n; }
pub fn dbgApplyArrLen(i: usize) u32 { if (i >= dbg_applyarr_n) return 0; return dbg_applyarr_len[i]; }
pub fn dbgApplyArrE0(i: usize) u8 { if (i >= dbg_applyarr_n) return 255; return dbg_applyarr_e0[i]; }
pub fn dbgApplyArrE1(i: usize) u8 { if (i >= dbg_applyarr_n) return 255; return dbg_applyarr_e1[i]; }
pub fn dbgApplyArrE0Type(i: usize) u8 { if (i >= dbg_applyarr_n) return 255; return dbg_applyarr_e0type[i]; }
pub fn dbgApplyArrE0Prop(i: usize, k: usize) []const u8 { if (i >= dbg_applyarr_n or k >= 3) return ""; return values.getString(dbg_applyarr_e0prop[i][k]); }

// Count `.stack` reads — the inner VM reads `err.stack` ONLY at its type-144
// error-accumulator (h += ":" + err.stack), so this = # errors folded into the
// payload (the direct null-token cause). jsdom-equivalent target: 0.
pub var dbg_stack_reads: u32 = 0;
pub fn dbgStackReads() u32 { return dbg_stack_reads; }
pub var dbg_stack_msgs: [8][96]u8 = undefined;
pub var dbg_stack_msg_len: [8]usize = [_]usize{0} ** 8;
pub var dbg_stack_msg_n: usize = 0;
pub fn dbgStackMsgCount() usize { return dbg_stack_msg_n; }
pub fn dbgStackMsg(i: usize) []const u8 { if (i >= dbg_stack_msg_n) return ""; return dbg_stack_msgs[i][0..dbg_stack_msg_len[i]]; }

/// True if `name` is one of the method names whose non-function resolution
/// causes the payload-inflating throws we're hunting.
fn isProbeMethodName(name: []const u8) bool {
    return eql(name, "apply") or eql(name, "call") or eql(name, "toString") or
        eql(name, "replace") or eql(name, "String") or eql(name, "removeEventListener") or
        eql(name, "addEventListener") or eql(name, "appendChild") or eql(name, "concat");
}


fn run() Value {
    var steps: u64 = 0;
    const MAX_STEPS: u64 = execution_limit; // guard against infinite loops
    while (true) {
        if (values.exhausted) { fail("string arena exhausted"); return error_value; }
        if (had_error) break;
        if (frame_count == 0) break;
        steps += 1;
        if (steps >= MAX_STEPS) {
            // Snapshot the op ring so we can see the looping instruction window.
            dbg_steplimit_op_n = 0;
            const oc = @min(op_ring.len, op_ring_pos);
            var oj: usize = 0;
            while (oj < oc) : (oj += 1) {
                const oi = (op_ring_pos - oc + oj) % op_ring.len;
                dbg_steplimit_op[dbg_steplimit_op_n] = op_ring[oi];
                dbg_steplimit_op_n += 1;
            }
            if (frame_count > 0) { dbg_steplimit_func = frames[frame_count - 1].func_id; dbg_steplimit_ip = frames[frame_count - 1].ip; }
            fail("step limit exceeded");
            return error_value;
        }

        // Refetch each iteration: eval() appends bytecode to the shared buffer
        // at runtime, so the live length must be re-read.
        const bc = compiler.getBytecode();

        var frame = &frames[frame_count - 1];
        if (frame.ip >= bc.len) break;
        const op: Op = @enumFromInt(bc[frame.ip]);
        frame.ip += 1;
        if (objects.dbg_track_active) {
            objects.dbg_active_func = frame.func_id; objects.dbg_active_ip = frame.ip;
            // Snapshot the top (up to 6) VM frame func ids so native-triggered
            // writes can be attributed to the invoking VM function.
            const fc = frame_count;
            objects.dbgSetFrameStack(
                if (fc >= 1) frames[fc - 1].func_id else 0xFFFF,
                if (fc >= 2) frames[fc - 2].func_id else 0xFFFF,
                if (fc >= 3) frames[fc - 3].func_id else 0xFFFF,
                if (fc >= 4) frames[fc - 4].func_id else 0xFFFF,
                if (fc >= 5) frames[fc - 5].func_id else 0xFFFF,
                if (fc >= 6) frames[fc - 6].func_id else 0xFFFF,
                @intCast(@min(fc, 6)));
        }

        if (execOne(op, bc, frame)) break; // execOne returns true on halt
    }

    // Return TOS or undefined
    return if (sp > 0) stack[sp - 1] else Value.UNDEFINED;
}

/// Execute a single opcode. Returns true if execution should halt.
/// `frame` is a live pointer into the frames array (valid for this dispatch).
// A synchronous host operation can invoke JS which transfers control to a
// caller's catch/finally. Preserve that handler's stack and abandon the host
// operation, even though a caught exception has already cleared had_error.
var operation_aborted: bool = false;
var operation_unwind_sp: u16 = 0;
fn callbackAborted() bool { return operation_aborted or had_error; }
const SyncCaller = struct {
    depth: u16,
    ip: u32,
    fn capture() SyncCaller {
        return .{ .depth = frame_count, .ip = if (frame_count > 0) frames[frame_count - 1].ip else 0 };
    }
    fn transferred(self: SyncCaller) bool {
        if (operation_aborted) return true;
        if (had_error or frame_count != self.depth or (self.depth > 0 and frames[self.depth - 1].ip != self.ip)) {
            operation_aborted = true;
            operation_unwind_sp = sp;
            return true;
        }
        return false;
    }
};
fn execOne(op: Op, bc: []const u8, frame: *CallFrame) bool {
    operation_aborted = false;
    const halted = execOneImpl(op, bc, frame);
    if (operation_aborted) sp = operation_unwind_sp;
    return halted;
}
fn execOneImpl(op: Op, bc: []const u8, frame: *CallFrame) bool {
    dbgHashEntry(frame);
        // Opcode-execution ring (for post-mortem of the failing instruction seq).
        op_ring[op_ring_pos % op_ring.len] = @intFromEnum(op);
        op_ring_ip[op_ring_pos % op_ring.len] = @intCast(frame.ip - 1);
        op_ring_pos += 1;
        // Targeted opcode trace: record the first N opcodes executed in a chosen
        // func_id (the resolve-loop writer), with the ip, to compare its control
        // flow against Node's version of the same function.
        if (dbg_ftrace_enabled and frame.func_id == dbg_ftrace_func and dbg_ftrace_n < dbg_ftrace_op.len) {
            dbg_ftrace_op[dbg_ftrace_n] = @intFromEnum(op);
            dbg_ftrace_ip[dbg_ftrace_n] = @intCast(frame.ip - 1 - frame_code_start(frame));
            dbg_ftrace_n += 1;
        }
        switch (op) {
            .nop => {},
            .halt => return true,

            .pop => { if (sp > 0) sp -= 1; },
            .dup => { if (sp > 0 and sp < MAX_STACK) { stack[sp] = stack[sp - 1]; sp += 1; } },
            .dup2 => { // [a,b] -> [a,b,a,b]
                if (sp >= 2 and sp + 1 < MAX_STACK) {
                    const a = stack[sp - 2];
                    const b = stack[sp - 1];
                    stack[sp] = a;
                    stack[sp + 1] = b;
                    sp += 2;
                }
            },
            .swap => { if (sp >= 2) { const tmp = stack[sp - 1]; stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = tmp; } },
            .close_scope => {
                const first = readU16(bc, &frame.ip);
                closeUpvalues(@as(u32, frame.bp) + first);
            },

            // Constants
            .load_const => {
                const idx = readU16(bc, &frame.ip);
                push(constToValue(idx));
            },
            .load_undef => push(Value.UNDEFINED),
            .load_null => push(Value.NULL),
            .load_true => push(Value.TRUE),
            .load_false => push(Value.FALSE),
            .load_zero => push(Value.number(0)),
            .load_one => push(Value.number(1)),

            // Variables
            .get_local => {
                const slot = readU16(bc, &frame.ip);
                const abs = frame.bp + slot;
                const lv = if (abs < MAX_STACK) stack[abs] else Value.UNDEFINED;
                push(lv);
            },
            .set_local => {
                const slot = readU16(bc, &frame.ip);
                const abs = frame.bp + slot;
                // Trace writes to a watched ABSOLUTE address (Tt's K slot) from
                // ANY frame — catches cross-frame slot corruption.
                if (dbg_slot15_watch != 0xFFFFFFFF and abs == dbg_slot15_watch and dbg_slot15_n < 16) {
                    const pv2 = peek();
                    dbg_slot15_func[dbg_slot15_n] = frame.func_id;
                    dbg_slot15_slot[dbg_slot15_n] = slot;
                    dbg_slot15_tag[dbg_slot15_n] = @intFromEnum(pv2.tag);
                    dbg_slot15_ip[dbg_slot15_n] = frame.ip;
                    if (pv2.tag == .string) dbg_slot15_slen[dbg_slot15_n] = @intCast(values.getStringLen(pv2.data.str_idx)) else dbg_slot15_slen[dbg_slot15_n] = 0;
                    dbg_slot15_n += 1;
                }
                // Func-filtered `t` write trace: record EVERY set_local to slot
                // `dbg_twrite_slot` while executing func `dbg_twrite_func` (483),
                // keeping the LAST N (ring), so we see what `t` was assigned and
                // any later reassignment — ignoring unrelated frames reusing the
                // same absolute address.
                if (frame.func_id == dbg_twrite_func and slot == dbg_twrite_slot) {
                    const pv3 = peek();
                    const wi = dbg_twrite_n % dbg_twrite_tag.len;
                    dbg_twrite_tag[wi] = @intFromEnum(pv3.tag);
                    dbg_twrite_ip[wi] = frame.ip;
                    dbg_twrite_num[wi] = if (pv3.tag == .number) pv3.data.number else -987654.0;
                    dbg_twrite_objtype[wi] = if (pv3.tag == .object or pv3.tag == .array) @intFromEnum(objects.objTypeOf(pv3.data.obj_idx)) else 255;
                    if (pv3.tag == .string) { const ss = values.getString(pv3.data.str_idx); const cn = @min(ss.len, 32); @memcpy(dbg_twrite_str[wi][0..cn], ss[0..cn]); dbg_twrite_slen[wi] = cn; } else dbg_twrite_slen[wi] = 0;
                    // Record Y (local 4) and x (local 2 obj) for this invocation.
                    const yv = stack[frame.bp + 4];
                    dbg_twrite_y[wi] = if (yv.tag == .number) @intFromFloat(@floor(yv.data.number)) else -1;
                    const xv2 = stack[frame.bp + 2];
                    dbg_twrite_xobj[wi] = if (xv2.tag == .object or xv2.tag == .array) xv2.data.obj_idx else 0xFFFFFFFF;
                    // On the FIRST bad (string) write, snapshot bank.Y[Y] = the
                    // register cell, and its `.create`/`.concat` closures' g.
                    if (pv3.tag == .string and !dbg_badcell_captured and (xv2.tag == .object or xv2.tag == .array) and yv.tag == .number) {
                        dbg_badcell_captured = true;
                        const bankobj = xv2.data.obj_idx;
                        const yprop = values.internString("Y");
                        const ybank = objects.getProperty(bankobj, yprop);
                        if (ybank.tag == .object or ybank.tag == .array) {
                            const cellv = objects.getArrayElement(ybank.data.obj_idx, @intFromFloat(@floor(yv.data.number)));
                            dbg_badcell_tag = @intFromEnum(cellv.tag);
                            if (cellv.tag == .object or cellv.tag == .array) {
                                const cellobj = cellv.data.obj_idx;
                                dbg_badcell_obj = cellobj;
                                dbg_badcell_objtype = @intFromEnum(objects.objTypeOf(cellobj));
                                // Probe `create` method's closure g (uv0).
                                // Probe `.prototype` and `.value` on the cell.
                                const protoname = values.internString("prototype");
                                const protov = objects.getProperty(cellobj, protoname);
                                dbg_badcell_proto_tag = @intFromEnum(protov.tag);
                                dbg_badcell_proto_hasown = if (objects.hasOwnProperty(cellobj, protoname)) 1 else 0;
                                if (protov.tag == .function) dbg_badcell_proto_fid = objects.closureFuncId(protov.data.func_idx);
                                // Also check if `prototype` resolves as a GETTER.
                                var pgetter: Value = Value.UNDEFINED;
                                if (objects.getPropertyGetter(cellobj, protoname, &pgetter) and pgetter.tag == .function) {
                                    dbg_badcell_proto_getter_fid = objects.closureFuncId(pgetter.data.func_idx);
                                }
                                if (protov.tag == .string) { const ps2 = values.getString(protov.data.str_idx); const cn4 = @min(ps2.len, 32); @memcpy(dbg_badcell_proto_str[0..cn4], ps2[0..cn4]); dbg_badcell_proto_slen = cn4; }
                                const valuename = values.internString("value");
                                dbg_badcell_value_tag = @intFromEnum(objects.getProperty(cellobj, valuename).tag);
                                dbg_badcell_value_hasown = if (objects.hasOwnProperty(cellobj, valuename)) 1 else 0;
                                const crname = values.internString("create");
                                const crm = objects.getProperty(cellobj, crname);
                                if (crm.tag == .function) {
                                    const cfo = crm.data.func_idx;
                                    dbg_badcell_create_fid = objects.closureFuncId(cfo);
                                    if (objects.closureUpvalCount(cfo) > 0) {
                                        var gv3 = Value.UNDEFINED;
                                        if (objects.isClosureUpvalClosed(cfo, 0)) gv3 = objects.getClosureUpvalClosedVal(cfo, 0)
                                        else { const a = objects.getClosureUpvalAddr(cfo, 0); if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) gv3 = stack[a]; }
                                        dbg_badcell_g_tag = @intFromEnum(gv3.tag);
                                        if (gv3.tag == .string) { const gs = values.getString(gv3.data.str_idx); const cn2 = @min(gs.len, 32); @memcpy(dbg_badcell_g_str[0..cn2], gs[0..cn2]); dbg_badcell_g_slen = cn2; }
                                    }
                                }
                            }
                        }
                    }
                    dbg_twrite_n += 1;
                }
                // O-state probe: record writes to the watched func's P slot so we
                // can see the state-machine transition sequence and pinpoint the
                // divergent state (P should reach the loop-exit value in Node).
                if (frame.func_id == dbg_ostate_func and dbg_ostate_n < dbg_ostate_val.len) {
                    if (slot == dbg_ostate_slot) {
                        const pv = peek();
                        dbg_ostate_val[dbg_ostate_n] = if (pv.tag == .number) pv.data.number else -88888;
                        dbg_ostate_ip[dbg_ostate_n] = @intCast(frame.ip);
                        // Snapshot reg 166's length alongside each state transition:
                        // `this` = local0 (frame.bp); this.Y[166].length = Lt.length.
                        { var r166l: i32 = -1;
                          if (frame.bp < MAX_STACK) { const thisv = stack[frame.bp];
                            if (thisv.tag == .object or thisv.tag == .array) {
                              const yv = objects.getProperty(thisv.data.obj_idx, values.internString("Y"));
                              if (yv.tag == .object or yv.tag == .array) {
                                const r166 = getElemFromValue(yv, Value.number(166));
                                if (r166.tag == .object or r166.tag == .array) r166l = @intCast(objects.arrayLength(r166.data.obj_idx));
                              } } }
                          dbg_ostate_r166[dbg_ostate_n] = r166l; }
                        dbg_ostate_n += 1;
                    }
                }
                // Capture dL (func 286 local 25 = g[1][1]) contents the first time it's set.
                if (frame.func_id == dbg_dl_func and slot == 25 and !dbg_dl_done) {
                    const dv = peek();
                    if (dv.tag == .object or dv.tag == .array) {
                        dbg_dl_done = true;
                        const di = dv.data.obj_idx;
                        dbg_dl_len = objects.arrayLength(di);
                        var k: usize = 0;
                        while (k < 16 and k < dbg_dl_len) : (k += 1) {
                            const ev = objects.getArrayElement(di, @intCast(k));
                            dbg_dl_vals[k] = if (ev.tag == .number) ev.data.number else -1;
                        }
                    }
                }
                // Corruption watch: does this set_local write into an address
                // owned by a DIFFERENT live ancestor frame's local region?
                if (!dbg_wcorrupt_detected and frame.func_id != 0xFFFF and frame.func_id != 0xFFFE) {
                    var afi: usize = 0;
                    while (afi + 1 < frame_count) : (afi += 1) {
                        const anc = frames[afi];
                        if (anc.func_id == 0xFFFF or anc.func_id == 0xFFFE) continue;
                        if (anc.bp == frame.bp) continue;
                        const alc = compiler.getFunction(anc.func_id).local_count;
                        if (abs >= anc.bp and abs < @as(u32, anc.bp) + alc) {
                            dbg_wcorrupt_detected = true;
                            dbg_wcorrupt_anc_func = anc.func_id;
                            dbg_wcorrupt_anc_bp = anc.bp;
                            dbg_wcorrupt_anc_lc = alc;
                            dbg_wcorrupt_anc_depth = @intCast(afi);
                            dbg_wcorrupt_writer_depth = frame_count - 1;
                        }
                    }
                }
                if (frame.func_id == dbg_slotwatch_func) {
                    if (slot == 137) {
                        dbg_slotwatch_137_writes += 1;
                        dbg_slotwatch_137_tag = @intFromEnum(peek().tag);
                        dbg_slotwatch_137_bp = frame.bp;
                        dbg_slotwatch_137_ip = @intCast(frame.ip);
                        // Recent lookup names leading to this value.
                        dbg_s137_l0 = if (lookup_ring_pos >= 1) lookup_ring[(lookup_ring_pos - 1) % lookup_ring.len] else 0;
                        dbg_s137_l1 = if (lookup_ring_pos >= 2) lookup_ring[(lookup_ring_pos - 2) % lookup_ring.len] else 0;
                        dbg_s137_l2 = if (lookup_ring_pos >= 3) lookup_ring[(lookup_ring_pos - 3) % lookup_ring.len] else 0;
                        // Snapshot opcode ring at the (last) slot-137 write.
                        dbg_s137_op_n = 0;
                        const ocount = @min(op_ring.len, op_ring_pos);
                        var oj: usize = 0;
                        while (oj < ocount) : (oj += 1) {
                            const oi = (op_ring_pos - ocount + oj) % op_ring.len;
                            dbg_s137_op[dbg_s137_op_n] = op_ring[oi];
                            dbg_s137_op_n += 1;
                        }
                    }
                    if (slot > dbg_slotwatch_maxslot) dbg_slotwatch_maxslot = slot;
                }
                if (dbg_watch_addr != 0xFFFFFFFF and abs == dbg_watch_addr) {
                    dbg_watch_writes += 1;
                    dbg_watch_last_tag = @intFromEnum(peek().tag);
                    dbg_watch_last_bp = frame.bp;
                    dbg_watch_last_slot = slot;
                    dbg_watch_last_func = frame.func_id;
                    dbg_watch_last_framecount = frame_count;
                    dbg_watch_last_lc = compiler.getFunction(frame.func_id).local_count;
                }
                if (abs < MAX_STACK) stack[abs] = peek();
            },
            .get_global => {
                const name_idx = readU16(bc, &frame.ip);
                const name_str = constToStringIdx(name_idx);
                setLookupName(name_str);
                if (dbg_callrec_on and eql(values.getString(name_str), "atob")) dbg_atob_lookups += 1;
                // Reading an UNDECLARED global throws ReferenceError (JS
                // semantics). BotGuard's feature-detection and error-encoding
                // depend on this. A global that exists (even set to undefined)
                // does not throw — hasOwnProperty distinguishes the two.
                if (!objects.hasOwnProperty(global_obj, name_str)) {
                    if (dbg_wtrack_char != 0) { const nm = values.getString(name_str); if (nm.len == 1 and nm[0] == dbg_wtrack_char) { dbg_w_refError_count += 1; dbg_w_defglobal_at_referror = dbg_w_defglobal_count; } }
                    throwReferenceError(values.getString(name_str));
                } else {
                    const gv = objects.getProperty(global_obj, name_str);
                    // Debug: record the first get_global that returns undefined
                    // (a defined-but-undefined global feeding NaN arithmetic).
                    if (gv.tag == .undefined and !dbg_undefglobal_captured) {
                        dbg_undefglobal_captured = true;
                        const gs = values.getString(name_str);
                        const gk = @min(gs.len, dbg_undefglobal_name.len);
                        @memcpy(dbg_undefglobal_name[0..gk], gs[0..gk]);
                        dbg_undefglobal_name_len = gk;
                        if (frame_count > 0) { dbg_undefglobal_func = frames[frame_count - 1].func_id; dbg_undefglobal_ip = frames[frame_count - 1].ip; }
                    }
                    push(gv);
                }
            },
            .get_global_safe => {
                // Non-throwing global read (for `typeof`): missing -> undefined.
                const name_idx = readU16(bc, &frame.ip);
                const name_str = constToStringIdx(name_idx);
                setLookupName(name_str);
                push(objects.getProperty(global_obj, name_str));
            },
            .set_global => {
                const name_idx = readU16(bc, &frame.ip);
                const name_str = constToStringIdx(name_idx);
                const sgv = peek();
                objects.setProperty(global_obj, name_str, sgv);
            },
            .def_global => {
                const name_idx = readU16(bc, &frame.ip);
                const name_str = constToStringIdx(name_idx);
                if (dbg_wtrack_char != 0) { const nm = values.getString(name_str); if (nm.len == 1 and nm[0] == dbg_wtrack_char) { dbg_w_defglobal_count += 1; dbg_w_last_defglobal_func = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF; } }
                const dgv = pop();
                objects.setProperty(global_obj, name_str, dgv);
            },
            .get_upval => {
                const idx = readU16(bc, &frame.ip);
                var uv = Value.UNDEFINED;
                // Debug: record the most recent get_upval that returned undefined,
                // with its cell state, so a downstream .Mw/.concat-on-undefined
                // fault can be traced to the capture.
                if (frame.closure_obj != objects.NULL_OBJ) {
                    dbg_lastuv_func = frame.func_id;
                    dbg_lastuv_idx = idx;
                    dbg_lastuv_closed = objects.isClosureUpvalClosed(frame.closure_obj, idx);
                    dbg_lastuv_addr = objects.getClosureUpvalAddr(frame.closure_obj, idx);
                    dbg_lastuv_closure = frame.closure_obj;
                    dbg_lastuv_upcount = compiler.upvalCount(frame.func_id);
                }
                if (frame.closure_obj != objects.NULL_OBJ) {
                    if (objects.isClosureUpvalClosed(frame.closure_obj, idx)) {
                        uv = objects.getClosureUpvalClosedVal(frame.closure_obj, idx);
                    } else {
                        const addr = objects.getClosureUpvalAddr(frame.closure_obj, idx);
                        if (addr != objects.NO_UPVAL_ADDR and addr < MAX_STACK) {
                            uv = stack[addr];
                        }
                    }
                }
                if (frame.closure_obj != objects.NULL_OBJ) dbg_lastuv_readtag = @intFromEnum(uv.tag);
                // Capture the FIRST get_upval that reads a long string (the program
                // base64, ~9784 chars) — identifies the faulting closure (op287
                // handler reading K as the program string instead of the bank).
                if (!dbg_badupval_done and uv.tag == .string) {
                    const slen = values.getStringLen(uv.data.str_idx);
                    if (slen > 5000) {
                        dbg_badupval_done = true;
                        dbg_badupval_func = frame.func_id;
                        dbg_badupval_idx = idx;
                        dbg_badupval_closure = frame.closure_obj;
                        dbg_badupval_upcount = compiler.upvalCount(frame.func_id);
                        dbg_badupval_slen = @intCast(slen);
                        dbg_badupval_closed = if (objects.isClosureUpvalClosed(frame.closure_obj, idx)) 1 else 0;
                    }
                }
                push(uv);
            },
            .set_upval => {
                // Write through the captured variable: to the live stack slot
                // while the owning frame is alive (open), or to the closed
                // snapshot after it returned. By-reference so all sharers see it.
                const idx = readU16(bc, &frame.ip);
                const v = peek();
                if (dbg_binding_name) |name| {
                    if (dbg_binding_write_count < dbg_binding_write_func.len and eql(values.getString(compiler.funcUpvalName(frame.func_id, idx)), name)) {
                        const wi = dbg_binding_write_count;
                        dbg_binding_write_func[wi] = frame.func_id;
                        dbg_binding_write_ip[wi] = frame.ip;
                        dbg_binding_write_value[wi] = v;
                        dbg_binding_write_count += 1;
                    }
                }
                if (frame.closure_obj != objects.NULL_OBJ) {
                    if (objects.isClosureUpvalClosed(frame.closure_obj, idx)) {
                        objects.setClosureUpvalClosedVal(frame.closure_obj, idx, v);
                    } else {
                        const addr = objects.getClosureUpvalAddr(frame.closure_obj, idx);
                        if (addr != objects.NO_UPVAL_ADDR and addr < MAX_STACK) {
                            stack[addr] = v;
                        }
                    }
                }
            },

            // Property access
            .get_prop => {
                const name_idx = readU16(bc, &frame.ip);
                const obj_val = pop();
                const name_str = constToStringIdx(name_idx);
                setLookupName(name_str);
                // Diagnostic: while recording, capture any single-char property
                // read whose value is a string starting with "E:" (BotGuard's
                // error accumulator, whatever its rotated name) — if such a field
                // PINPOINT: reading a bank field ('H') off a FUNCTION receiver is
                // the op-64 handler symptom (its K should be a bank). Capture the
                // reading frame + the op that produced the function receiver, once.
                if (!dbg_fnbank_done and obj_val.tag == .function) {
                    const nm2 = values.getString(name_str);
                    if (nm2.len == 1 and (nm2[0] == 'H' or nm2[0] == 'O')) {
                        dbg_fnbank_done = true;
                        if (frame_count > 0) {
                            dbg_fnbank_func = frames[frame_count - 1].func_id;
                            dbg_fnbank_closure = frames[frame_count - 1].closure_obj;
                            dbg_fnbank_upcount = compiler.upvalCount(frames[frame_count - 1].func_id);
                        }
                        // The CALLER frame (the op-64 handler that passed the
                        // function as D's bank arg) — this is the frame whose K
                        // upvalue is wrong.
                        if (frame_count > 1) {
                            dbg_fnbank_caller = frames[frame_count - 2].func_id;
                            dbg_fnbank_caller_closure = frames[frame_count - 2].closure_obj;
                            dbg_fnbank_caller_upcount = compiler.upvalCount(frames[frame_count - 2].func_id);
                        }
                        dbg_fnbank_funcidx = obj_val.data.func_idx;
                        // op that produced obj_val (op_ring[pos-2]) + its upval idx.
                        if (op_ring_pos >= 2) {
                            const pi = (op_ring_pos - 2) % op_ring.len;
                            dbg_fnbank_prevop = op_ring[pi];
                            const pop2: Op = @enumFromInt(op_ring[pi]);
                            if (pop2 == .get_upval and op_ring_ip[pi] + 2 < bc.len) {
                                dbg_fnbank_uvidx = @as(u16, bc[op_ring_ip[pi] + 1]) | (@as(u16, bc[op_ring_ip[pi] + 2]) << 8);
                            }
                        }
                    }
                }
                // is set, the interpreter dispatch skips running the program.
                if (dbg_callrec_on and (obj_val.tag == .object or obj_val.tag == .array)) {
                    const nm = values.getString(name_str);
                    if (nm.len <= 2) {
                        const wv = getPropFromValue(obj_val, name_str);
                        if (wv.tag == .string) {
                            const ws = values.getString(wv.data.str_idx);
                            if (ws.len >= 2 and ws[0] == 'E' and ws[1] == ':') {
                                dbg_lastW_tag = @intFromEnum(wv.tag);
                                dbg_lastW_reads += 1;
                                const wn = @min(ws.len, dbg_lastW_str.len);
                                @memcpy(dbg_lastW_str[0..wn], ws[0..wn]);
                                dbg_lastW_str_len = wn;
                            }
                        }
                    }
                }
                // JS: reading a property of undefined/null throws TypeError.
                if (obj_val.tag == .undefined or obj_val.tag == .null_val) {
                    if (!dbg_firstpropthrow_captured) {
                        dbg_firstpropthrow_captured = true;
                        dbg_firstpropthrow_name = name_str;
                        dbg_firstpropthrow_recv = prev_lookup_name;
                        dbg_firstpropthrow_isnull = (obj_val.tag == .null_val);
                        if (frame_count > 0) dbg_firstpropthrow_func = frames[frame_count - 1].func_id;
                        // recent lookup path snapshot
        dbg_fpt_l0 = if (lookup_ring_pos >= 2) lookup_ring[(lookup_ring_pos - 2) % lookup_ring.len] else 0;
                        dbg_fpt_l1 = if (lookup_ring_pos >= 3) lookup_ring[(lookup_ring_pos - 3) % lookup_ring.len] else 0;
                        dbg_fpt_l2 = if (lookup_ring_pos >= 4) lookup_ring[(lookup_ring_pos - 4) % lookup_ring.len] else 0;
                        dbg_fpt_l3 = if (lookup_ring_pos >= 5) lookup_ring[(lookup_ring_pos - 5) % lookup_ring.len] else 0;
                        dbg_fpt_l4 = if (lookup_ring_pos >= 6) lookup_ring[(lookup_ring_pos - 6) % lookup_ring.len] else 0;
                        dbg_fpt_l5 = if (lookup_ring_pos >= 7) lookup_ring[(lookup_ring_pos - 7) % lookup_ring.len] else 0;
                        // Snapshot the opcode ring (oldest->newest) at this throw.
                        dbg_fpt_op_n = 0;
                        const ocount = @min(op_ring.len, op_ring_pos);
                        var oj: usize = 0;
                        while (oj < ocount) : (oj += 1) {
                            const oi = (op_ring_pos - ocount + oj) % op_ring.len;
                            dbg_fpt_op[dbg_fpt_op_n] = op_ring[oi];
                            dbg_fpt_op_n += 1;
                        }
                    }
                    // Capture receiver provenance for the payload-inflating
                    // `undefined.String`/`.prototype`/`.toString` throws (BEFORE
                    // the throw returns). op_ring[pos-2] produced obj_val.
                    if (!dbg_recvprov_captured and obj_val.tag == .undefined) {
                        const pnm = values.getString(name_str);
                        if (eql(pnm, "String") or eql(pnm, "prototype") or eql(pnm, "toString")) {
                            dbg_recvprov_captured = true;
                            // Capture the bytecode window around this get_prop so we
                            // can detect IP-desync (get_prop reached mid-instruction).
                            // frame.ip currently points AFTER the u16 operand; the
                            // instruction began at frame.ip-3 (opcode + 2 operand).
                            dbg_crpbytes_ip = if (frame.ip >= 3) frame.ip - 3 else 0;
                            dbg_crpbytes_nameidx = name_idx;
                            {
                                var bi: usize = 0;
                                const bstart: usize = if (frame.ip >= 12) frame.ip - 12 else 0;
                                while (bi < dbg_crpbytes.len and bstart + bi < bc.len) : (bi += 1) {
                                    dbg_crpbytes[bi] = bc[bstart + bi];
                                }
                                dbg_crpbytes_n = bi;
                                dbg_crpbytes_start = @intCast(bstart);
                            }
                            if (op_ring_pos >= 2) {
                                const prev_i = (op_ring_pos - 2) % op_ring.len;
                                dbg_recvprov_op = op_ring[prev_i];
                                const prev_ip = op_ring_ip[prev_i];
                                const prev_op: Op = @enumFromInt(op_ring[prev_i]);
                                if (prev_op == .get_upval and prev_ip + 2 < bc.len) {
                                    const uidx: u16 = @as(u16, bc[prev_ip + 1]) | (@as(u16, bc[prev_ip + 2]) << 8);
                                    dbg_recvprov_upval_idx = uidx;
                                    dbg_recvprov_upval_count = compiler.upvalCount(frame.func_id);
                                    const ud = compiler.upvalDescAt(frame.func_id, @intCast(uidx));
                                    dbg_recvprov_ud_islocal = ud.is_local;
                                    dbg_recvprov_ud_index = ud.index;
                                    if (frame.closure_obj != objects.NULL_OBJ) {
                                        dbg_recvprov_upval_closed = objects.isClosureUpvalClosed(frame.closure_obj, uidx);
                                        dbg_recvprov_upval_addr = objects.getClosureUpvalAddr(frame.closure_obj, uidx);
                                        if (dbg_recvprov_upval_addr != objects.NO_UPVAL_ADDR and dbg_recvprov_upval_addr < MAX_STACK) {
                                            dbg_recvprov_addr_tag = @intFromEnum(stack[dbg_recvprov_upval_addr].tag);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Byte-window capture at the guaranteed throw site (detect IP desync).
                    if (dbg_crpbytes_n == 0 and eql(values.getString(name_str), "String")) {
                        dbg_crpbytes_ip = if (frame.ip >= 3) frame.ip - 3 else 0;
                        dbg_crpbytes_nameidx = name_idx;
                        const bstart: usize = if (frame.ip >= 12) frame.ip - 12 else 0;
                        var bi: usize = 0;
                        while (bi < dbg_crpbytes.len and bstart + bi < bc.len) : (bi += 1) dbg_crpbytes[bi] = bc[bstart + bi];
                        dbg_crpbytes_n = bi;
                        dbg_crpbytes_start = @intCast(bstart);
                    }
                    throwCannotReadProp(obj_val.tag == .null_val, values.getString(name_str));
                    return false;
                }
                // Capture provenance the first time we read `.prototype` off an
                // undefined receiver: which opcode produced the undefined value,
                // and (if get_upval) the upvalue index + closed state.
                if (!dbg_recvprov_captured and obj_val.tag == .undefined and
                    (eql(values.getString(name_str), "prototype") or eql(values.getString(name_str), "String")))
                {
                    dbg_recvprov_captured = true;
                    // op_ring[pos-1] is the current get_prop; pos-2 produced obj_val.
                    if (op_ring_pos >= 2) {
                        const prev_i = (op_ring_pos - 2) % op_ring.len;
                        dbg_recvprov_op = op_ring[prev_i];
                        const prev_ip = op_ring_ip[prev_i];
                        const prev_op: Op = @enumFromInt(op_ring[prev_i]);
                        if (prev_op == .get_upval and prev_ip + 2 < bc.len) {
                            const uidx: u16 = @as(u16, bc[prev_ip + 1]) | (@as(u16, bc[prev_ip + 2]) << 8);
                            dbg_recvprov_upval_idx = uidx;
                            if (frame.closure_obj != objects.NULL_OBJ) {
                                dbg_recvprov_upval_closed = objects.isClosureUpvalClosed(frame.closure_obj, uidx);
                                dbg_recvprov_closure = frame.closure_obj;
                                dbg_recvprov_upval_count = compiler.upvalCount(frame.func_id);
                                dbg_recvprov_upval_addr = objects.getClosureUpvalAddr(frame.closure_obj, uidx);
                                if (dbg_recvprov_upval_addr != objects.NO_UPVAL_ADDR and dbg_recvprov_upval_addr < MAX_STACK) {
                                    dbg_recvprov_addr_tag = @intFromEnum(stack[dbg_recvprov_upval_addr].tag);
                                }
                                dbg_recvprov_cur_bp = frame.bp;
                                dbg_recvprov_cur_sp = sp;
                                // Upvalue descriptor: is_local + index in enclosing frame.
                                const ud = compiler.upvalDescAt(frame.func_id, @intCast(uidx));
                                dbg_recvprov_ud_islocal = ud.is_local;
                                dbg_recvprov_ud_index = ud.index;
                                // Find the frame that owns the captured address.
                                const want = dbg_recvprov_upval_addr;
                                var fi: usize = 0;
                                while (fi < frame_count) : (fi += 1) {
                                    const f = frames[fi];
                                    const fl = compiler.getFunction(f.func_id).local_count;
                                    if (want >= f.bp and want < @as(u32, f.bp) + fl) {
                                        dbg_recvprov_owner_func = f.func_id;
                                        dbg_recvprov_owner_bp = f.bp;
                                        dbg_recvprov_owner_lc = fl;
                                    }
                                }
                            }
                        } else if ((prev_op == .get_local or prev_op == .get_global) and prev_ip + 2 < bc.len) {
                            dbg_recvprov_slot = @as(u16, bc[prev_ip + 1]) | (@as(u16, bc[prev_ip + 2]) << 8);
                        }
                    }
                }
                const gp_result = getPropFromValue(obj_val, name_str);
                // WATCH: `.H` read inside the FH-site-2 closure (func 157). Capture
                // the receiver tag/obj (even if a number) and the result tag/num,
                // to see whether `r` is wrong or `r.H` holds a number.
                // `.H` read in func 157 (FH-site-2 closure). Key on FUNC ID (the
                // intern id for "H" differs between the harness and the post-reset
                // VM table, so we can't match by name from the harness). Record the
                // FIRST read whose receiver OR result is a NUMBER (the bug), plus
                // running counts.
                if (dbg_hread_watch and frame_count > 0 and frames[frame_count - 1].func_id == dbg_hread_func_filter) {
                    dbg_hread_total += 1;
                    const bad = (obj_val.tag == .number) or (gp_result.tag == .number);
                    const good = (obj_val.tag == .object and gp_result.tag == .object);
                    if (good) dbg_hread_good += 1;
                    if (bad) dbg_hread_bad += 1;
                    // Capture the FIRST read's recv+res (to compare with the bad read).
                    if (dbg_hread_first_tag == 255) {
                        dbg_hread_first_recv = if (obj_val.tag == .object or obj_val.tag == .array) obj_val.data.obj_idx else 0xFFFFFFFF;
                        dbg_hread_first_tag = @intFromEnum(gp_result.tag);
                        dbg_hread_first_res = if (gp_result.tag == .object or gp_result.tag == .array or gp_result.tag == .function) gp_result.data.obj_idx else 0xFFFFFFFF;
                    }
                    if (!dbg_hread_done and bad) {
                        dbg_hread_done = true;
                        dbg_hread_recv_tag = @intFromEnum(obj_val.tag);
                        dbg_hread_recv_obj = if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function) obj_val.data.obj_idx else 0xFFFFFFFF;
                        dbg_hread_recv_num = if (obj_val.tag == .number) obj_val.data.number else -987654.0;
                        dbg_hread_res_tag = @intFromEnum(gp_result.tag);
                        dbg_hread_res_num = if (gp_result.tag == .number) gp_result.data.number else -987654.0;
                        dbg_hread_res_obj = if (gp_result.tag == .object or gp_result.tag == .array or gp_result.tag == .function) gp_result.data.obj_idx else 0xFFFFFFFF;
                        dbg_hread_func = frames[frame_count - 1].func_id;
                        dbg_hread_bad_at = dbg_hread_total;
                        // At the BAD read: does the receiver still have its OWN "H"?
                        if (obj_val.tag == .object or obj_val.tag == .array) {
                            const roi2 = obj_val.data.obj_idx;
                            dbg_hread_bad_hasown = if (objects.hasOwnProperty(roi2, name_str)) 1 else 0;
                            // Also report whether a getter is found on the chain for this name.
                            var g2: Value = Value.UNDEFINED;
                            dbg_hread_bad_getter = if (objects.getPropertyGetter(roi2, name_str, &g2)) 1 else 0;
                            dbg_hread_bad_objtype = @intFromEnum(objects.objTypeOf(roi2));
                            dbg_hread_bad_propcount = objects.getObject(roi2).prop_count;
                            dbg_hread_bad_arraylen = objects.getObject(roi2).array_len;
                            // Count how many OWN "H" nodes obj has (duplicate detection).
                            dbg_hread_bad_dupH = objects.dbgCountOwnProp(roi2, name_str);
                        }
                    }
                }
                if (name_str == dbg_T_name_idx and (obj_val.tag == .object or obj_val.tag == .array)) {
                    dbg_Tget_count += 1;
                    dbg_Tget_last_owner = obj_val.data.obj_idx;
                    dbg_Tget_last_arr = if (gp_result.tag == .array or gp_result.tag == .object) gp_result.data.obj_idx else 0xFFFFFFFF;
                }
                // WATCH: first read of "aR" — capture receiver, own-vs-inherited,
                // result tag, and the receiver's prototype chain, to see why F.aR
                // resolves to a getter instead of F's own array.
                if (dbg_aRread_watch and !dbg_aRread_done and name_str == dbg_aRread_name and (obj_val.tag == .object or obj_val.tag == .array)) {
                    dbg_aRread_done = true;
                    const roi = obj_val.data.obj_idx;
                    dbg_aRread_recv = roi;
                    dbg_aRread_own = if (objects.hasOwnProperty(roi, name_str)) 1 else 0;
                    dbg_aRread_restag = @intFromEnum(gp_result.tag);
                    dbg_aRread_func = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
                    // prototype chain (up to 6 levels) + which level has own "aR".
                    var cur = roi; var lvl: u8 = 0;
                    dbg_aRread_chain_n = 0; dbg_aRread_own_level = 255;
                    while (cur != objects.NULL_OBJ and lvl < 6) : (lvl += 1) {
                        dbg_aRread_chain[lvl] = cur;
                        if (objects.hasOwnProperty(cur, name_str) and dbg_aRread_own_level == 255) dbg_aRread_own_level = lvl;
                        dbg_aRread_chain_n = lvl + 1;
                        cur = objects.getObjectPrototypeIdx(cur);
                    }
                }
                push(gp_result);
            },
            .set_prop => {
                const name_idx = readU16(bc, &frame.ip);
                const val = pop();
                const obj_val = pop();
                const name_str = constToStringIdx(name_idx);
                // WATCH: set_prop "prototype" onto a PLAIN object via the interpreter
                // bytecode. Capture the first, with func/ip, to see if BotGuard truly
                // assigns it (then jsdom would too) or it's our bug.
                if (objects.dbg_ps_watch and !objects.dbg_ps_done and name_idx == objects.dbg_ps_name and
                    (obj_val.tag == .object) and objects.objTypeOf(obj_val.data.obj_idx) == .object)
                {
                    objects.dbg_ps_done = true;
                    objects.dbg_ps_obj = obj_val.data.obj_idx;
                    objects.dbg_ps_valtag = @intFromEnum(val.tag);
                    if (frame_count > 0) { objects.dbg_ps_func = frames[frame_count - 1].func_id; objects.dbg_ps_ip = frames[frame_count - 1].ip; }
                }
                if (name_str == dbg_S_name_idx) {
                    dbg_S_set_count += 1;
                    dbg_S_last_val = if (val.tag == .number) @intFromFloat(val.data.number) else -1;
                    dbg_S_last_tag = @intFromEnum(val.tag);
                }
                if (name_str == dbg_rD_name_idx) {
                    dbg_rD_set_count += 1;
                    dbg_rD_last_owner = if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function) obj_val.data.obj_idx else 0xFFFFFFFF;
                    dbg_rD_last_val = if (val.tag == .object or val.tag == .array or val.tag == .function) val.data.obj_idx else 0xFFFFFFFE;
                }
                if (name_str == dbg_Y_name_idx and val.tag == .number) {
                    dbg_Y_set_count += 1;
                    dbg_Y_last_val = @intFromFloat(val.data.number);
                }
                if (name_str == dbg_ox_name_idx and (val.tag == .array or val.tag == .object)) {
                    dbg_ox_set_count += 1;
                    dbg_ox_last_len = objects.arrayLength(@intCast(val.data.obj_idx));
                    objects.dbg_ox_obj = @intCast(val.data.obj_idx);
                }
                if (name_str == dbg_T_name_idx and (obj_val.tag == .object or obj_val.tag == .array)) {
                    dbg_T_reassign_count += 1;
                    dbg_T_last_owner = obj_val.data.obj_idx;
                    dbg_T_last_arr = if (val.tag == .array or val.tag == .object) val.data.obj_idx else 0xFFFFFFFF;
                    if (dbg_T_hist_n < dbg_T_hist_owner.len) {
                        dbg_T_hist_owner[dbg_T_hist_n] = dbg_T_last_owner;
                        dbg_T_hist_arr[dbg_T_hist_n] = dbg_T_last_arr;
                        // How many numeric register-writes had happened, the
                        // length of the new bank, and the current function id.
                        dbg_T_hist_setelem[dbg_T_hist_n] = dbg_setelem_total;
                        dbg_T_hist_arrlen[dbg_T_hist_n] = if (val.tag == .array or val.tag == .object) objects.arrayLength(@intCast(val.data.obj_idx)) else 0;
                        dbg_T_hist_func[dbg_T_hist_n] = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
                        dbg_T_hist_n += 1;
                    }
                }
                setPropOnValue(obj_val, name_str, val);
                if (obj_val.tag == .undefined or obj_val.tag == .null_val or callbackAborted()) return false;
                push(val);
            },
            .get_elem => {
                const key = pop();
                const obj_val = pop();
                // JS: computed member access `obj[key]` on undefined/null throws
                // a TypeError (same as dotted access). Without this, a read like
                // `undefined['replace']` silently returns undefined, so a caller
                // that should abort (e.g. `u(T,slot,P[t])` with P undefined) instead
                // stores undefined, clobbering a register (root of the op#134-adjacent
                // pI#6 divergence: slot 125/101 overwritten with undefined).
                if (obj_val.tag == .undefined or obj_val.tag == .null_val) {
                    const key_name: []const u8 = if (key.tag == .string) values.getString(key.data.str_idx) else "";
                    if (!dbg_emptyge_captured and key_name.len == 0) {
                        dbg_emptyge_captured = true;
                        dbg_emptyge_keytag = @intFromEnum(key.tag);
                        dbg_emptyge_keynum = key.toNumber();
                        if (frame_count > 0) {
                            dbg_emptyge_func = frames[frame_count - 1].func_id;
                            dbg_emptyge_ip = frames[frame_count - 1].ip;
                        }
                        // Record global `f`'s tag/obj so we can see if the wrong
                        // `f` (one without `.v`) was published by exposeAllLiveScopes.
                        {
                            const gf = objects.getProperty(global_obj, values.internString("f"));
                            dbg_emptyge_gf_tag = @intFromEnum(gf.tag);
                            dbg_emptyge_gf_obj = if (gf.tag == .object or gf.tag == .array or gf.tag == .function) gf.data.obj_idx else 0xFFFFFFFF;
                            if (gf.tag == .object or gf.tag == .array) {
                                const hv = objects.hasOwnProperty(gf.data.obj_idx, values.internString("v"));
                                dbg_emptyge_gf_hasv = if (hv) 1 else 0;
                            }
                            // Count live frames that declare a local named `f`,
                            // and record the func_id of the NEAREST such frame.
                            var ff: usize = frame_count;
                            var slot: usize = 0;
                            while (ff > 0) {
                                ff -= 1;
                                const fr = frames[ff];
                                if (slot < dbg_emptyge_framelist.len) { dbg_emptyge_framelist[slot] = fr.func_id; slot += 1; }
                                if (fr.func_id == 0xFFFF or fr.func_id == 0xFFFE or fr.func_id >= 0xF000) continue;
                                const cnt2 = compiler.funcNameTabCount(fr.func_id);
                                var j: u16 = 0;
                                while (j < cnt2) : (j += 1) {
                                    const nm2 = compiler.funcLocalName(fr.func_id, j);
                                    if (nm2 == 0xFFFFFFFF) continue;
                                    const s2 = values.getString(nm2);
                                    if (s2.len == 1 and s2[0] == 'f') {
                                        dbg_emptyge_fframes += 1;
                                        if (dbg_emptyge_nearest_ffunc == 0xFFFF) dbg_emptyge_nearest_ffunc = fr.func_id;
                                    }
                                }
                            }
                            dbg_emptyge_framelist_n = slot;
                        }
                    }
                    // Receiver provenance for computed `undefined["String"]` etc.
                    if (!dbg_recvprov_captured and obj_val.tag == .undefined and key.tag == .string) {
                        const pnm = values.getString(key.data.str_idx);
                        if (eql(pnm, "String") or eql(pnm, "prototype") or eql(pnm, "toString")) {
                            dbg_recvprov_captured = true;
                            // op_ring[pos-1]=current get_elem; the KEY was pushed
                            // last, the RECEIVER before it. Walk back to find the
                            // op that produced the receiver (skip the key-producing op).
                            if (op_ring_pos >= 3) {
                                const recv_i = (op_ring_pos - 3) % op_ring.len;
                                dbg_recvprov_op = op_ring[recv_i];
                                const recv_ip = op_ring_ip[recv_i];
                                const recv_op: Op = @enumFromInt(op_ring[recv_i]);
                                if (recv_op == .get_upval and recv_ip + 2 < bc.len) {
                                    const uidx: u16 = @as(u16, bc[recv_ip + 1]) | (@as(u16, bc[recv_ip + 2]) << 8);
                                    dbg_recvprov_upval_idx = uidx;
                                    dbg_recvprov_upval_count = compiler.upvalCount(frame.func_id);
                                    const ud = compiler.upvalDescAt(frame.func_id, @intCast(uidx));
                                    dbg_recvprov_ud_islocal = ud.is_local;
                                    dbg_recvprov_ud_index = ud.index;
                                    if (frame.closure_obj != objects.NULL_OBJ) {
                                        dbg_recvprov_upval_closed = objects.isClosureUpvalClosed(frame.closure_obj, uidx);
                                        dbg_recvprov_upval_addr = objects.getClosureUpvalAddr(frame.closure_obj, uidx);
                                        if (dbg_recvprov_upval_addr != objects.NO_UPVAL_ADDR and dbg_recvprov_upval_addr < MAX_STACK) {
                                            dbg_recvprov_addr_tag = @intFromEnum(stack[dbg_recvprov_upval_addr].tag);
                                        }
                                    }
                                } else if (recv_op == .get_local and recv_ip + 2 < bc.len) {
                                    // Local slot index; record it + the local's current value tag.
                                    const lslot: u16 = @as(u16, bc[recv_ip + 1]) | (@as(u16, bc[recv_ip + 2]) << 8);
                                    dbg_recvprov_slot = lslot;
                                    const addr: u32 = @as(u32, frame.bp) + lslot;
                                    if (addr < MAX_STACK) dbg_recvprov_addr_tag = @intFromEnum(stack[addr].tag);
                                    dbg_recvprov_owner_func = frame.func_id;
                                    dbg_recvprov_cur_bp = frame.bp;
                                }
                            }
                        }
                    }
                    // Byte-window + key capture at the get_elem throw site.
                    if (dbg_crpbytes_n == 0 and eql(key_name, "String")) {
                        dbg_crpbytes_ip = frame.ip;
                        dbg_crpbytes_nameidx = @intFromEnum(key.tag);
                        const bstart: usize = if (frame.ip >= 16) frame.ip - 16 else 0;
                        var bi: usize = 0;
                        while (bi < dbg_crpbytes.len and bstart + bi < bc.len) : (bi += 1) dbg_crpbytes[bi] = bc[bstart + bi];
                        dbg_crpbytes_n = bi;
                        dbg_crpbytes_start = @intCast(bstart);
                        // Record the key string too.
                        const ks = @min(key_name.len, dbg_crpkey.len);
                        @memcpy(dbg_crpkey[0..ks], key_name[0..ks]);
                        dbg_crpkey_len = ks;
                        dbg_crpkey_is_elem = true;
                        // Snapshot the throwing frame's local slots (tags) + meta.
                        dbg_crpslots_func = frame.func_id;
                        dbg_crpslots_lc = compiler.getFunction(frame.func_id).local_count;
                        dbg_crpslots_pc = compiler.getFunction(frame.func_id).param_count;
                        dbg_crpslots_bp = frame.bp;
                        var si2: usize = 0;
                        while (si2 < dbg_crpslots_tag.len and frame.bp + si2 < MAX_STACK) : (si2 += 1) {
                            dbg_crpslots_tag[si2] = @intFromEnum(stack[frame.bp + si2].tag);
                        }
                        dbg_crpslots_n = si2;
                        // Capture the numeric values of func161 locals 1..6 (the register
                        // index `b` fed to Q, and the bank object x, live values).
                        {
                            var lv: usize = 0;
                            while (lv < 8 and frame.bp + lv < MAX_STACK) : (lv += 1) {
                                const sv = stack[frame.bp + lv];
                                dbg_crplocal_num[lv] = if (sv.tag == .number) sv.data.number else -999999;
                                dbg_crplocal_objidx[lv] = if (sv.tag == .object or sv.tag == .array) sv.data.obj_idx else 0xFFFFFFFF;
                            }
                            dbg_crplocal_n = lv;
                        }
                        // Snapshot func 161's upvalue value tags (esp. upval4 which
                        // produces the undefined local5 receiver).
                        dbg_crpupval_n = @min(compiler.upvalCount(frame.func_id), dbg_crpupval_tag.len);
                        if (frame.closure_obj != objects.NULL_OBJ) {
                            var ui: usize = 0;
                            while (ui < dbg_crpupval_n) : (ui += 1) {
                                var uvv = Value.UNDEFINED;
                                if (objects.isClosureUpvalClosed(frame.closure_obj, @intCast(ui))) {
                                    uvv = objects.getClosureUpvalClosedVal(frame.closure_obj, @intCast(ui));
                                } else {
                                    const a = objects.getClosureUpvalAddr(frame.closure_obj, @intCast(ui));
                                    if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) uvv = stack[a];
                                }
                                dbg_crpupval_tag[ui] = @intFromEnum(uvv.tag);
                                dbg_crpupval_funcidx[ui] = if (uvv.tag == .function) @intCast(objects.closureFuncId(uvv.data.func_idx)) else 0xFFFF;
                                // For u4 (index 4), also record its closure's upval0 value tag
                                // (should be the bY function; if undefined, that's the bug).
                                if (ui == 4 and uvv.tag == .function) {
                                    const clo4 = uvv.data.func_idx;
                                    dbg_crpu4_upvalcount = objects.closureUpvalCount(clo4);
                                    if (dbg_crpu4_upvalcount > 0) {
                                        var v0 = Value.UNDEFINED;
                                        if (objects.isClosureUpvalClosed(clo4, 0)) {
                                            v0 = objects.getClosureUpvalClosedVal(clo4, 0);
                                            dbg_crpu4_uv0_closed = 1;
                                        } else {
                                            const a0 = objects.getClosureUpvalAddr(clo4, 0);
                                            dbg_crpu4_uv0_addr = a0;
                                            if (a0 != objects.NO_UPVAL_ADDR and a0 < MAX_STACK) v0 = stack[a0];
                                        }
                                        dbg_crpu4_uv0_tag = @intFromEnum(v0.tag);
                                    }
                                }
                                const ud = compiler.upvalDescAt(frame.func_id, @intCast(ui));
                                dbg_crpupval_islocal[ui] = if (ud.is_local) 1 else 0;
                                dbg_crpupval_index[ui] = ud.index;
                            }
                        }
                        // Frame stack snapshot: func_id + src_start for top frames.
                        dbg_crpframe_n = @min(frame_count, dbg_crpframe_func.len);
                        var fi: usize = 0;
                        while (fi < dbg_crpframe_n) : (fi += 1) {
                            const f = frames[frame_count - 1 - fi];
                            dbg_crpframe_func[fi] = f.func_id;
                            dbg_crpframe_srcstart[fi] = compiler.getFunction(f.func_id).src_start;
                            dbg_crpframe_ip[fi] = f.ip;
                        }
                    }
                    throwCannotReadProp(obj_val.tag == .null_val, key_name);
                    return false;
                }
                const ge_res = getElemFromValue(obj_val, key);
                if ((dbg_gtrace_on or debug_function_entry != null) and dbg_property_key.tag == .undefined and key.tag == .string and eql(values.getString(key.data.str_idx), "webdriver") and dbg_gtrace_n < 12605) {
                    dbg_property_receiver = obj_val;
                    dbg_property_key = key;
                    dbg_property_result = ge_res;
                }
                if (dbg_gtrace_on and key.tag == .string and dbg_gtrace_n >= 7300 and dbg_gtrace_n <= 7450 and dbg_probe_n < dbg_probe_key.len) {
                    dbg_probe_key[dbg_probe_n] = key.data.str_idx;
                    dbg_probe_gn[dbg_probe_n] = dbg_gtrace_n;
                    dbg_probe_obj[dbg_probe_n] = obj_val;
                    dbg_probe_func[dbg_probe_n] = frame.func_id;
                    dbg_probe_n += 1;
                }
                // Provenance probe: record obj + key so a callee produced by
                // get_elem (T-bank read) can be traced to its exact index.
                dbg_lastgetelem_objidx = if (obj_val.tag == .object or obj_val.tag == .array) obj_val.data.obj_idx else 0xFFFFFFFF;
                dbg_lastgetelem_keytag = @intFromEnum(key.tag);
                dbg_lastgetelem_keynum = key.toNumber();
                if (key.tag == .string) {
                    const ks = values.getString(key.data.str_idx);
                    const kn = @min(ks.len, dbg_lastgetelem_keystr.len);
                    @memcpy(dbg_lastgetelem_keystr[0..kn], ks[0..kn]);
                    dbg_lastgetelem_keystr_len = kn;
                } else dbg_lastgetelem_keystr_len = 0;
                dbg_lastgetelem_result_functag = (ge_res.tag == .function);
                push(ge_res);
            },
            .set_elem => {
                const val = pop();
                const key = pop();
                const obj_val = pop();
                // WATCH: capture the FIRST set_elem whose VALUE is the string
                // "[object Function]" — that's the mis-stringified function source
                // being written into a register (bank). Record reg index + caller.
                if (!dbg_objfnwrite_done and val.tag == .string) {
                    const vs = values.getString(val.data.str_idx);
                    if (eql(vs, "[object Function]")) {
                        dbg_objfnwrite_done = true;
                        dbg_objfnwrite_reg = if (key.tag == .number) @intFromFloat(key.data.number) else -1;
                        dbg_objfnwrite_func = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
                        dbg_objfnwrite_ip = if (frame_count > 0) frames[frame_count - 1].ip else 0;
                    }
                }
                if (key.tag == .number and (obj_val.tag == .array or obj_val.tag == .object)) {
                    // Targeted: capture EVERY write to register index 74 (the one Q reads
                    // void), recording the value tag, and if the value is a cell object,
                    // its getter's closed-over g value tag — plus the writing func/ip.
                    if (@floor(key.data.number) == dbg_reg74_target and dbg_reg74_n < 16) {
                        // Remember the cell object installed here so we can watch
                        // its `.concat`/`.create` later (the g-mutation path).
                        if (val.tag == .function or val.tag == .object) {
                            dbg_reg74_last_cell = val.data.obj_idx;
                            // Auto-arm concat watch on the FIRST cell (object) installed
                            // at the target register, so we capture every value written
                            // to its closed-over g via `.concat(P)`.
                            if (val.tag == .object and dbg_concat_watch_obj == 0xFFFFFFFF) {
                                dbg_concat_watch_obj = val.data.obj_idx;
                                dbg_concat_n = 0;
                            }
                        }
                        dbg_reg74_valtag[dbg_reg74_n] = @intFromEnum(val.tag);
                        dbg_reg74_bankobj[dbg_reg74_n] = obj_val.data.obj_idx;
                        dbg_reg74_func[dbg_reg74_n] = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
                        dbg_reg74_ip[dbg_reg74_n] = if (frame_count > 0) frames[frame_count - 1].ip else 0;
                        // If the stored value is a closure/object with upvalues (a cell),
                        // record its first upvalue value tag (the getter's captured g).
                        if (val.tag == .function or val.tag == .object) {
                            const cobj = val.data.obj_idx;
                            const ucnt = objects.closureUpvalCount(cobj);
                            dbg_reg74_cell_upcount[dbg_reg74_n] = ucnt;
                            if (ucnt > 0) {
                                var gv = Value.UNDEFINED;
                                if (objects.isClosureUpvalClosed(cobj, 0)) gv = objects.getClosureUpvalClosedVal(cobj, 0)
                                else { const a = objects.getClosureUpvalAddr(cobj, 0); if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) gv = stack[a]; }
                                dbg_reg74_cell_g_tag[dbg_reg74_n] = @intFromEnum(gv.tag);
                            } else dbg_reg74_cell_g_tag[dbg_reg74_n] = 254;
                        } else dbg_reg74_cell_g_tag[dbg_reg74_n] = @intFromEnum(val.tag);
                        dbg_reg74_n += 1;
                    }
                    dbg_setelem_numeric += 1;
                    dbg_setelem_total += 1;
                    dbg_setelem_last_key = @intFromFloat(key.data.number);
                    dbg_setelem_last_obj = obj_val.data.obj_idx;
                    dbg_setelem_last_valtag = @intFromEnum(val.tag);
                    // Histogram which array objects receive numeric set_elem during
                    // the resolve loop, and by which function.
                    const tgt: u32 = obj_val.data.obj_idx;
                    const cf: u16 = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
                    var found = false;
                    var si: usize = 0;
                    while (si < dbg_se_obj_n) : (si += 1) { if (dbg_se_obj[si] == tgt) { dbg_se_obj_cnt[si] += 1; found = true; break; } }
                    if (!found and dbg_se_obj_n < dbg_se_obj.len) { dbg_se_obj[dbg_se_obj_n] = tgt; dbg_se_obj_cnt[dbg_se_obj_n] = 1; dbg_se_obj_func[dbg_se_obj_n] = cf; dbg_se_obj_n += 1; }
                    // Arm the per-function opcode trace on the first resolve-loop
                    // writer function we see, so we capture its control flow.
                    if (dbg_regfault_first_z >= 0 and !dbg_ftrace_enabled and cf != 0xFFFF) {
                        dbg_ftrace_func = cf;
                        dbg_ftrace_n = 0;
                        dbg_ftrace_enabled = true;
                    }
                }
                // ── Watch set_elem on the reg-363 cell object (any index): capture
                // index/value/caller to find who writes the seed elements.
                if (dbg_selem_watch_obj != 0xFFFFFFFF and (obj_val.tag == .object or obj_val.tag == .array)
                    and obj_val.data.obj_idx == dbg_selem_watch_obj and key.tag == .number and dbg_selem_n < 96) {
                    const j = dbg_selem_n;
                    dbg_selem_idx[j] = @intFromFloat(key.data.number);
                    dbg_selem_val[j] = if (val.tag == .number) val.data.number else -987654.0;
                    dbg_selem_caller[j] = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
                    dbg_selem_ip[j] = if (frame_count > 0) frames[frame_count - 1].ip else 0;
                    dbg_selem_n += 1;
                }
                setElemOnValue(obj_val, key, val);
                if (obj_val.tag == .undefined or obj_val.tag == .null_val or callbackAborted()) return false;
                push(val);
            },
            .get_optional => {
                const name_idx = readU16(bc, &frame.ip);
                const obj_val = pop();
                if (obj_val.tag == .undefined or obj_val.tag == .null_val) {
                    push(Value.UNDEFINED);
                } else {
                    const name_str = constToStringIdx(name_idx);
                    push(getPropFromValue(obj_val, name_str));
                }
            },
            .get_elem_optional => {
                const key = pop();
                const obj_val = pop();
                if (obj_val.tag == .undefined or obj_val.tag == .null_val) {
                    push(Value.UNDEFINED);
                } else {
                    push(getElemFromValue(obj_val, key));
                }
            },

            // Arithmetic
            .add => { const b = pop(); const a = pop(); const sum = addValues(a, b);
                if (dbg_encode_n == 65 and sum.tag == .string and eql(values.getString(sum.data.str_idx), "2")) { dbg_two_func = frame.func_id; dbg_two_a = a; dbg_two_b = b; dbg_two_reg = stack[frame.bp+3]; }
                push(sum); },
            .sub => { const b = pop(); const a = pop(); push(Value.number(a.toNumber() - b.toNumber())); },
            .mul => { const b = pop(); const a = pop(); push(Value.number(a.toNumber() * b.toNumber())); },
            .div => { const b = pop(); const a = pop(); push(Value.number(a.toNumber() / b.toNumber())); },
            // JavaScript % is truncating remainder: its sign follows the
            // dividend. Euclidean modulo changes negative transform operands.
            .mod => { const b = pop(); const a = pop(); push(Value.number(jsRemainder(a.toNumber(), b.toNumber()))); },
            .pow => { const b = pop(); const a = pop(); push(Value.number(mathPow(a.toNumber(), b.toNumber()))); },
            .neg => { const a = pop(); push(Value.number(-a.toNumber())); },
            .pos => { const a = pop(); push(Value.number(a.toNumber())); },

            // Bitwise
            .bit_and => { const b = pop(); const a = pop(); push(Value.number(@floatFromInt(toI32(a) & toI32(b)))); },
            .bit_or => { const b = pop(); const a = pop(); push(Value.number(@floatFromInt(toI32(a) | toI32(b)))); },
            .bit_xor => { const b = pop(); const a = pop(); push(Value.number(@floatFromInt(toI32(a) ^ toI32(b)))); },
            .bit_not => { const a = pop(); push(Value.number(@floatFromInt(~toI32(a)))); },
            .shl => { const b = pop(); const a = pop(); push(Value.number(@floatFromInt(shlI32(toI32(a), toU5(b))))); },
            .shr => { const b = pop(); const a = pop(); push(Value.number(@floatFromInt(shrI32(toI32(a), toU5(b))))); },
            .ushr => { const b = pop(); const a = pop(); push(Value.number(@floatFromInt(ushrU32(toU32(a), toU5(b))))); },

            // Comparison
            .eq => { const b = pop(); const a = pop();
                if (dbg_gtrace_on and dbg_gtrace_n >= dbg_register_first and dbg_gtrace_n <= dbg_register_last and frame.bp + 2 < MAX_STACK and stack[frame.bp + 2].toNumber() == dbg_register_watch[0]) { dbg_branch_a = a; dbg_branch_b = b; for (0..16) |j| dbg_branch_slots[j] = if (frame.bp + j < MAX_STACK) stack[frame.bp + j] else Value.UNDEFINED; }
                if (frame.func_id == 333 and dbg_guard_n < 64) {
                    const ev = stack[frame.bp+5];
                    if (ev.tag == .function and eql(compiler.funcSourceText(objects.closureFuncId(ev.data.func_idx)), "function(k){return x3.call(this,0,8,k)}")) {
                        dbg_guard_rows[dbg_guard_n] = .{ @floatFromInt(@intFromEnum(a.tag)), if (a.tag == .number) a.data.number else @floatFromInt(a.data.obj_idx), @floatFromInt(@intFromEnum(b.tag)), if (b.tag == .number) b.data.number else @floatFromInt(b.data.obj_idx), if (abstractEq(a,b)) 1 else 0 }; dbg_guard_n += 1;
                    }
                }
                push(boolVal(abstractEq(a, b))); },
            .neq => { const b = pop(); const a = pop();
                push(boolVal(!abstractEq(a, b))); },
            .seq => { const b = pop(); const a = pop(); push(boolVal(strictEq(a, b))); },
            .sneq => { const b = pop(); const a = pop(); push(boolVal(!strictEq(a, b))); },
            .lt => { const b = pop(); const a = pop(); push(boolVal(relationalOrder(a, b) == .less)); },
            .gt => { const b = pop(); const a = pop();
                if (dbg_gtrace_on and dbg_gtrace_n >= dbg_register_first and dbg_gtrace_n <= dbg_register_last and frame.bp + 2 < MAX_STACK and stack[frame.bp + 2].toNumber() == dbg_register_watch[0]) { dbg_branch_a = a; dbg_branch_b = b; for (0..16) |j| dbg_branch_slots[j] = if (frame.bp + j < MAX_STACK) stack[frame.bp + j] else Value.UNDEFINED; }
                // ROOT capture: the `Lt.length>4` compare in func 286 (z==96). Record
                // the LHS (Lt.length) whenever RHS==4 and we're in the state-machine func.
                if (dbg_gt4_watch and frame.func_id == dbg_gt4_func and b.tag == .number and b.data.number == 4 and dbg_gt4_n < dbg_gt4_val.len) {
                    dbg_gt4_val[dbg_gt4_n] = if (a.tag == .number) a.data.number else -1;
                    dbg_gt4_ip[dbg_gt4_n] = frame.ip;
                    dbg_gt4_n += 1;
                }
                push(boolVal(relationalOrder(a, b) == .greater)); },
            .lte => { const b = pop(); const a = pop(); const order = relationalOrder(a, b); push(boolVal(order == .less or order == .equal)); },
            .gte => { const b = pop(); const a = pop(); const order = relationalOrder(a, b); push(boolVal(order == .greater or order == .equal)); },
            .instanceof => {
                const b = pop();
                const a = pop();
                push(boolVal(if (dbg_disable_instanceof) false else instanceOf(a, b)));
            },
            .in_op => {
                // JS `key in obj`. If `obj` is not an object, throw TypeError
                // "Cannot use 'in' operator to search for '<key>' in <obj>".
                // BotGuard deliberately does `<x> in <number>` to generate this
                // error into its transcript (oc=693: `'' in 43`), so we MUST
                // throw with the exact message; the previous stub returned FALSE
                // and silently desynced the error budget + register decode.
                const b = pop();
                const a = pop();
                if (b.tag != .object and b.tag != .array and b.tag != .function) {
                    _ = inOpThrow(a, b);
                    return false;
                } else {
                    const oi: u32 = b.data.obj_idx;
                    const key_idx = builtins.keyToNameIdx(a);
                    // Array numeric index membership: `i in arr` is true iff i < length
                    // and the element is a hole-free slot. Route string/number keys.
                    var found = false;
                    if (objects.objTypeOf(oi) == .array) {
                        const ks = values.getString(key_idx);
                        if (parseArrayIndex(ks)) |idx| {
                            found = idx < objects.arrayLength(oi);
                        }
                    }
                    if (!found) {
                        // Own + prototype chain property presence.
                        var cur: u32 = oi;
                        var depth: u8 = 0;
                        while (cur != objects.NULL_OBJ and depth < 32) : (depth += 1) {
                            if (objects.hasOwnProperty(cur, key_idx)) { found = true; break; }
                            cur = objects.getObjectPrototypeIdx(cur);
                        }
                    }
                    push(boolVal(found));
                }
            },

            // Logical
            .not => { const a = pop(); push(boolVal(!a.isTruthy())); },
            .typeof_op => {
                const a = pop();
                if ((dbg_gtrace_on or debug_typeof_on) and dbg_type_n < dbg_type_gn.len) {
                    dbg_type_gn[dbg_type_n] = dbg_gtrace_n;
                    dbg_type_func[dbg_type_n] = frame.func_id;
                    dbg_type_name[dbg_type_n] = last_lookup_name;
                    dbg_type_value[dbg_type_n] = a;
                    dbg_type_key[dbg_type_n] = values.internString(dbg_lastgetelem_keystr[0..dbg_lastgetelem_keystr_len]);
                    dbg_type_obj[dbg_type_n] = dbg_lastgetelem_objidx;
                    for (0..3) |di| dbg_type_callers[dbg_type_n][di] = if (frame_count > di+1) frames[frame_count-di-2].func_id else 0xFFFF;
                    dbg_type_n += 1;
                }
                push(typeofValue(a));
            },
            .void_op => { _ = pop(); push(Value.UNDEFINED); },
            .delete_op => { _ = pop(); push(Value.TRUE); },

            // Control flow (4-byte absolute targets / relative loop offset)
            .jump => { const target = readU32(bc, &frame.ip); jumpTo(frame, target); },
            .jump_if_false => {
                const target = readU32(bc, &frame.ip);
                const v = pop();
                if (!v.isTruthy()) jumpTo(frame, target);
            },
            .jump_if_true => {
                const target = readU32(bc, &frame.ip);
                const v = pop();
                if (v.isTruthy()) jumpTo(frame, target);
            },
            .jump_nullish => {
                const target = readU32(bc, &frame.ip);
                const v = peek();
                if (v.tag == .null_val or v.tag == .undefined) jumpTo(frame, target);
            },
            .loop_back => {
                const offset = readU32(bc, &frame.ip);
                jumpTo(frame, frame.ip - offset);
            },

            // Functions and calls
            .call => {
                const argc = bc[frame.ip];
                frame.ip += 1;
                // Hh handler-dispatch capture: when func dbg_hh_func (our Hh=f88)
                // makes a call, record the callee func id + arg0 (the opcode/handler)
                // so we can see which handler runs per opcode and how it advances.
                if (dbg_hh_watch and frame.func_id == dbg_hh_func and dbg_hh_n < dbg_hh_callee.len and argc >= 1) {
                    const callee_slot = sp - argc - 1;
                    if (callee_slot < MAX_STACK) {
                        const cv = stack[callee_slot];
                        if (cv.tag == .function) dbg_hh_callee[dbg_hh_n] = objects.closureFuncId(cv.data.func_idx) else dbg_hh_callee[dbg_hh_n] = 0xFFFE;
                        dbg_hh_ip[dbg_hh_n] = frame.ip;
                        dbg_hh_n += 1;
                    }
                }
                // vP discovery+capture: find the call `vP(true,true,15,false,a,w)` and
                // record w.bI (=F.bI) — the tamper-check field (jsdom=0; ours suspected >0).
                if (dbg_vp_watch and argc == 6 and dbg_vp_n < dbg_vp_bi_arr.len) {
                    const a0 = stack[sp - argc];
                    const a2 = stack[sp - argc + 2];
                    if (a0.tag == .boolean and a0.data.boolean == 1 and a2.tag == .number and a2.data.number == 15) {
                        const wv = stack[sp - argc + 5]; // 6th arg = w (=F)
                        if (wv.tag == .object or wv.tag == .array) {
                            // Capture the vP callee func id (once).
                            if (dbg_vp_func == 0xFFFF) { const cs = sp - argc - 1; if (cs < MAX_STACK) { const cv = stack[cs]; if (cv.tag == .function) dbg_vp_func = objects.closureFuncId(cv.data.func_idx); } }
                            const wo = wv.data.obj_idx;
                            const bIv = objects.getProperty(wo, values.internString("bI"));
                            dbg_vp_bi_arr[dbg_vp_n] = if (bIv.tag == .number) bIv.data.number else -999999;
                            // Also capture the sub-conditions of r for this call.
                            const uv = objects.getProperty(wo, values.internString("u"));
                            const gev = objects.getProperty(wo, values.internString("ge"));
                            const wqv = objects.getProperty(wo, values.internString("w$"));
                            const fv = objects.getProperty(wo, values.internString("F"));
                            const xv = objects.getProperty(wo, values.internString("X"));
                            // encode flags into one number: u(1)+ge(2)+wq<=1(4)+!F(8)+!X(16)
                            var flags: u32 = 0;
                            if (uv.tag == .boolean and uv.data.boolean == 1) flags |= 1;
                            if (gev.tag == .boolean and gev.data.boolean == 1) flags |= 2;
                            if (wqv.tag == .number and wqv.data.number <= 1) flags |= 4;
                            if (fv.tag == .undefined or (fv.tag == .boolean and fv.data.boolean == 0) or fv.tag == .null_val) flags |= 8;
                            if (xv.tag == .undefined or (xv.tag == .boolean and xv.data.boolean == 0) or xv.tag == .null_val) flags |= 16;
                            dbg_vp_flags_arr[dbg_vp_n] = flags;
                            dbg_vp_pending = true; // next dbg_vp_func return fills this call's ret
                            dbg_vp_n += 1;
                        }
                    }
                }
                callFunction(argc);
            },
            .call_direct_eval => {
                const argc = bc[frame.ip];
                frame.ip += 1;
                // Mark that the callee is being invoked as a DIRECT eval so the
                // eval intrinsic compiles the source in the CALLER's lexical
                // scope. Only affects the case where the callee resolves to the
                // eval intrinsic; a shadowed `eval` local is called normally.
                eval_is_direct = true;
                callFunction(argc);
                eval_is_direct = false;
            },
            .call_method => {
                const argc = bc[frame.ip];
                frame.ip += 1;
                callMethod(argc);
            },
            .ret => {
                const result = pop();
                // ── Capture the func that returns a STRING to a func-483 caller
                // (i.e. the `v` in `t=v(x,Y)`), once — identifies the real reader.
                if (!dbg_vcallee_captured and result.tag == .string and frame_count >= 2
                    and frames[frame_count - 2].func_id == 483) {
                    dbg_vcallee_captured = true;
                    dbg_vcallee_func = frame.func_id;
                    dbg_vcallee_ip = frames[frame_count - 2].ip;
                    const rs2 = values.getString(result.data.str_idx);
                    const cn3 = @min(rs2.len, dbg_vcallee_str.len);
                    @memcpy(dbg_vcallee_str[0..cn3], rs2[0..cn3]);
                    dbg_vcallee_str_len = cn3;
                }
                // ── func-40 (cell .concat) capture: it returns f = g[p]. Capture
                // the FIRST string-return (the bad reg-116 case) and the FIRST
                // array/object-return (a good reg) so we can diff p, g[p], the
                // counter upvalues, and g[]. func 40 = function(P,Z,p,f){...}:
                // locals L0=recv,L1=P,L2=Z,L3=p,L4=f ; upvalues capture F,D,r,Y,x,g,W.
                if (frame.func_id == 40) {
                    // Ring: record func-40 returns for the TARGET receiver cell
                    // (reg-116 cell; deterministic obj on the pinned run). If the
                    // target is unset (0xFFFFFFFF) record all.
                    const recvv0 = stack[frame.bp]; // this (receiver) is bp slot 0
                    const recvobj0: u32 = if (recvv0.tag == .object or recvv0.tag == .array) recvv0.data.obj_idx else 0xFFFFFFFF;
                    if ((dbg_f40_target_recv == 0xFFFFFFFF or recvobj0 == dbg_f40_target_recv) and dbg_f40ring_n < dbg_f40ring_rtag.len) {
                        const k = dbg_f40ring_n;
                        dbg_f40ring_rtag[k] = @intFromEnum(result.tag);
                        const recvv = stack[frame.bp]; // this (receiver) is bp slot 0
                        dbg_f40ring_recv[k] = if (recvv.tag == .object or recvv.tag == .array) recvv.data.obj_idx else 0xFFFFFFFF;
                        const pR = stack[frame.bp + 3];
                        dbg_f40ring_p[k] = if (pR.tag == .number) pR.data.number else -987654.0;
                        if (result.tag == .string) {
                            const rsx = values.getString(result.data.str_idx);
                            const cn = @min(rsx.len, 40); @memcpy(dbg_f40ring_str[k][0..cn], rsx[0..cn]); dbg_f40ring_slen[k] = cn;
                        }
                        dbg_f40ring_n += 1;
                    }
                    // Detailed slot[0] = first string-return FROM THE TARGET CELL
                    // (reg-116 cell 1826); slot[1] = first array-return from any cell.
                    const is_str = result.tag == .string;
                    const is_arr = result.tag == .object or result.tag == .array;
                    const on_target = (dbg_f40_target_recv == 0xFFFFFFFF or recvobj0 == dbg_f40_target_recv);
                    const slot = if (is_str and on_target and !dbg_f40_str_done) @as(i32, 0)
                        else if (is_arr and !dbg_f40_arr_done) @as(i32, 1) else @as(i32, -1);
                    if (slot >= 0) {
                        const si: usize = @intCast(slot);
                        if (slot == 0) dbg_f40_str_done = true else dbg_f40_arr_done = true;
                        dbg_f40_rtag[si] = @intFromEnum(result.tag);
                        const pL3 = stack[frame.bp + 3];
                        dbg_f40_p[si] = if (pL3.tag == .number) pL3.data.number else -987654.0;
                        // Returned f: if string, record it; if array, its first elems.
                        if (result.tag == .string) {
                            const fs = values.getString(result.data.str_idx);
                            const cn = @min(fs.len, 32); @memcpy(dbg_f40_fstr[si][0..cn], fs[0..cn]); dbg_f40_fslen[si] = cn;
                        }
                        // Closure upvalues (F,D,r,Y,x,g,W in some order) — snapshot
                        // the first 12 upvalue value tags+numbers + find the g array.
                        const clo = frame.closure_obj;
                        const uvc = objects.closureUpvalCount(clo);
                        dbg_f40_uvcount[si] = uvc;
                        var ui: u16 = 0;
                        while (ui < uvc and ui < 12) : (ui += 1) {
                            var uv: Value = Value.UNDEFINED;
                            if (objects.isClosureUpvalClosed(clo, ui)) uv = objects.getClosureUpvalClosedVal(clo, ui)
                            else { const a = objects.getClosureUpvalAddr(clo, ui); if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) uv = stack[a]; }
                            dbg_f40_uvtag[si][ui] = @intFromEnum(uv.tag);
                            dbg_f40_uvnum[si][ui] = if (uv.tag == .number) uv.data.number else -987654.0;
                            // If this upvalue is the g array (object/array with len>=10), snapshot it.
                            if (uv.tag == .object or uv.tag == .array) {
                                const gi = uv.data.obj_idx;
                                const gl = objects.arrayLength(gi);
                                if (gl >= 8 and dbg_f40_glen[si] == 0) {
                                    dbg_f40_glen[si] = gl;
                                    dbg_f40_guv[si] = ui;
                                    var ge: usize = 0;
                                    while (ge < 16 and ge < gl) : (ge += 1) {
                                        const gev = objects.getArrayElement(gi, @intCast(ge));
                                        dbg_f40_gtag[si][ge] = @intFromEnum(gev.tag);
                                        dbg_f40_gnum[si][ge] = if (gev.tag == .number) gev.data.number else -987654.0;
                                        if (gev.tag == .string) {
                                            const ges = values.getString(gev.data.str_idx);
                                            const gcn = @min(ges.len, 15); @memcpy(dbg_f40_gstr[si][ge][0..gcn], ges[0..gcn]); dbg_f40_gstrlen[si][ge] = gcn;
                                        }
                                    }
                                    // Also capture g[p] directly (p may be fractional/out-of-range).
                                    if (pL3.tag == .number) {
                                        const pf = pL3.data.number;
                                        if (pf >= 0 and pf < @as(f64, @floatFromInt(gl))) {
                                            const gpv = objects.getArrayElement(gi, @intFromFloat(@floor(pf)));
                                            dbg_f40_gp_tag[si] = @intFromEnum(gpv.tag);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // ── v()-return capture: when func 113 (the register reader `v`)
                // returns a STRING, record which bank/reg/cell produced it, once.
                if (!dbg_vret_captured and frame.func_id == 113
                    and stack[frame.bp + 2].tag == .number
                    and @floor(stack[frame.bp + 2].data.number) == @as(f64, @floatFromInt(dbg_vret_want_reg))) {
                    dbg_vret_captured = true;
                    dbg_vret_result_tag = @intFromEnum(result.tag);
                    const bL1 = stack[frame.bp + 1]; // b (bank)
                    const xL2 = stack[frame.bp + 2]; // x (reg index)
                    const gL3 = stack[frame.bp + 3]; // g (cell object)
                    dbg_vret_bank = if (bL1.tag == .object or bL1.tag == .array) bL1.data.obj_idx else 0xFFFFFFFF;
                    dbg_vret_reg = if (xL2.tag == .number) @intFromFloat(@floor(xL2.data.number)) else -1;
                    dbg_vret_cell = if (gL3.tag == .object or gL3.tag == .array or gL3.tag == .function) gL3.data.obj_idx else 0xFFFFFFFF;
                    dbg_vret_cell_tag = @intFromEnum(gL3.tag);
                    if (result.tag == .string) {
                        const rs = values.getString(result.data.str_idx);
                        const cn = @min(rs.len, dbg_vret_str.len);
                        @memcpy(dbg_vret_str[0..cn], rs[0..cn]);
                        dbg_vret_str_len = cn;
                    }
                }
                returnFromFrame(result);
            },
            .ret_undef => {
                returnFromFrame(Value.UNDEFINED);
            },

            // Construction
            .make_regexp => {
                const flags = pop();
                const pattern = pop();
                const args = [_]Value{ pattern, flags };
                const result = builtins.callNative(builtins.N_REGEXP_CTOR, &args, 2);
                if (checkNativeThrow()) return false;
                push(result);
            },
            .define_literal_property => {
                const kind = bc[frame.ip]; frame.ip += 1;
                const value = pop();
                const key = pop();
                const object = peek();
                const name = builtins.keyToNameIdx(key);
                if (callbackAborted()) return false;
                if (object.tag == .object) objects.defineLiteralProperty(object.data.obj_idx, name, value, kind);
            },
            .make_object => {
                const count = bc[frame.ip];
                frame.ip += 1;
                const obj_idx = objects.createObject();
                // Define pairs in source order: the last duplicate wins and
                // string keys retain their creation order for enumeration.
                const pair_count: usize = @min(count, sp / 2);
                const start = sp - pair_count * 2;
                var i: usize = 0;
                while (i < pair_count) : (i += 1) {
                        const key = stack[start + i * 2];
                        const val = stack[start + i * 2 + 1];
                        if (key.tag == .string) {
                            objects.setProperty(obj_idx, key.data.str_idx, val);
                        }
                }
                sp = @intCast(start);
                push(Value.object(obj_idx));
            },
            .make_array => {
                const count = readU16(bc, &frame.ip);
                const arr_idx = objects.createArray(count);
                // Pop elements (in reverse)
                var i: u16 = count;
                while (i > 0) {
                    i -= 1;
                    const elem = pop();
                    objects.setArrayElement(arr_idx, i, elem);
                }
                // ── Watch: capture the make_array whose first element == the
                // wrong block-517 seed Z0 (dbg_mkarr_watch_e0), with caller+elems.
                if (dbg_mkarr_watch_e0 != 0 and !dbg_mkarr_done and count >= 1) {
                    const f0 = objects.getArrayElement(arr_idx, 0);
                    if (f0.tag == .number and @as(i64, @intFromFloat(f0.data.number)) == dbg_mkarr_watch_e0) {
                        dbg_mkarr_done = true;
                        dbg_mkarr_obj = arr_idx;
                        dbg_mkarr_count = count;
                        if (frame_count > 0) { dbg_mkarr_func = frames[frame_count - 1].func_id; dbg_mkarr_ip = frames[frame_count - 1].ip; }
                        var mi: usize = 0;
                        while (mi < 4 and mi < count) : (mi += 1) {
                            const ev = objects.getArrayElement(arr_idx, @intCast(mi));
                            dbg_mkarr_elems[mi] = if (ev.tag == .number) ev.data.number else -987654.0;
                        }
                    }
                }
                push(Value.object(arr_idx));
            },
            .make_func => {
                const func_id = readU16(bc, &frame.ip);
                const n_uv = compiler.upvalCount(func_id);
                if (n_uv == 0) {
                    const obj_idx = objects.createFunction(func_id);
                    push(Value.function(obj_idx));
                } else {
                    // Build a closure capturing upvalue ADDRESSES (by-reference).
                    // is_local -> absolute stack addr of the current frame's local
                    // (frame.bp + slot); !is_local -> the parent closure's captured
                    // address for that upvalue. Reads/writes go through the live
                    // stack so writes after capture are visible.
                    const clo = objects.createClosure(func_id, n_uv);
                    // Capture ONE target closure's full descriptor list (first
                    // closure with n_uv >= dbg_mkuv_min_uv, once).
                    if (dbg_mkuv_trace and !dbg_mkuv_done and
                        (dbg_mkuv_want_func == 0xFFFF or func_id == dbg_mkuv_want_func) and
                        n_uv >= dbg_mkuv_min_uv and
                        (dbg_mkuv_want_params == 0xFFFF or compiler.getFunction(func_id).param_count == dbg_mkuv_want_params)) {
                        dbg_mkuv_done = true;
                        dbg_mkuv_target_func = func_id;
                        dbg_mkuv_target_nuv = n_uv;
                        dbg_mkuv_target_bp = frame.bp;
                        dbg_mkuv_encl_func = frame.func_id;
                        dbg_mkuv_encl_lc = compiler.getFunction(frame.func_id).local_count;
                        dbg_mkuv_encl_pc = compiler.getFunction(frame.func_id).param_count;
                        // Snapshot the enclosing frame's slots 0..31 tags.
                        var sj: u32 = 0;
                        while (sj < 32) : (sj += 1) {
                            const sa: u32 = @as(u32, frame.bp) + sj;
                            dbg_mkuv_frameslot[sj] = if (sa < MAX_STACK) @intFromEnum(stack[sa].tag) else 255;
                        }
                        var uj: u16 = 0;
                        while (uj < n_uv and uj < 16) : (uj += 1) {
                            const dd = compiler.upvalDescAt(func_id, @intCast(uj));
                            dbg_mkuv_d_islocal[uj] = if (dd.is_local) 1 else 0;
                            dbg_mkuv_d_index[uj] = dd.index;
                            if (dd.is_local) {
                                const aa: u32 = @as(u32, frame.bp) + dd.index;
                                dbg_mkuv_d_valtag[uj] = if (aa < MAX_STACK) @intFromEnum(stack[aa].tag) else 255;
                                dbg_mkuv_d_addr[uj] = aa;
                            } else {
                                // Transitive: resolve the parent closure's upvalue
                                // VALUE tag so we can see if the relay is broken.
                                const pp = frame.closure_obj;
                                const ppidx: u16 = @intCast(dd.index);
                                if (pp != objects.NULL_OBJ) {
                                    if (objects.isClosureUpvalClosed(pp, ppidx)) {
                                        dbg_mkuv_d_valtag[uj] = @intFromEnum(objects.getClosureUpvalClosedVal(pp, ppidx).tag);
                                        dbg_mkuv_d_addr[uj] = 0xFFFFFFF0; // marker: closed
                                    } else {
                                        const pa = objects.getClosureUpvalAddr(pp, ppidx);
                                        dbg_mkuv_d_addr[uj] = pa;
                                        dbg_mkuv_d_valtag[uj] = if (pa != objects.NO_UPVAL_ADDR and pa < MAX_STACK) @intFromEnum(stack[pa].tag) else 253;
                                    }
                                } else { dbg_mkuv_d_valtag[uj] = 254; dbg_mkuv_d_addr[uj] = 0xFFFFFFFF; }
                            }
                        }
                    }
                    var ui: u16 = 0;
                    while (ui < n_uv) : (ui += 1) {
                        const d = compiler.upvalDescAt(func_id, @intCast(ui));
                        if (d.is_local) {
                            // Direct capture of the current frame's local slot
                            // (by-reference to the live stack).
                            objects.setClosureUpvalAddr(clo, ui, @as(u32, frame.bp) + d.index);
                            // Capture: if this is_local upvalue's index exceeds
                            // the creating frame's declared local count, the addr
                            // points OUTSIDE the frame — a compiler/frame-size bug.
                            if (!dbg_mkuv_captured and d.index >= compiler.getFunction(frame.func_id).local_count) {
                                dbg_mkuv_captured = true;
                                dbg_mkuv_func = frame.func_id;
                                dbg_mkuv_bp = frame.bp;
                                dbg_mkuv_lc = compiler.getFunction(frame.func_id).local_count;
                                dbg_mkuv_index = d.index;
                                dbg_mkuv_childfunc = func_id;
                            }
                        } else if (frame.closure_obj != objects.NULL_OBJ) {
                            // Captures keep sharing the variable's cell after
                            // its owner returns. Copying a closed value would
                            // split the binding and lose subsequent assignments.
                            const p = frame.closure_obj;
                            const pidx: u16 = @intCast(d.index);
                            objects.shareClosureUpvalCell(clo, ui, p, pidx);
                        }
                    }
                    if (dbg_binding_name) |name| {
                        var bi: u16 = 0;
                        while (bi < n_uv and dbg_binding_count < dbg_binding_closure.len) : (bi += 1) {
                            if (!eql(values.getString(compiler.funcUpvalName(func_id, bi)), name)) continue;
                            dbg_binding_closure[dbg_binding_count] = clo;
                            dbg_binding_index[dbg_binding_count] = bi;
                            dbg_binding_initial[dbg_binding_count] = dbgBindingValue(clo, bi);
                            dbg_binding_count += 1;
                        }
                    }
                    push(Value.function(clo));
                }
            },

            // Special
            .spread => {}, // handled by call/array construction
            .new_call => {
                const argc = bc[frame.ip];
                frame.ip += 1;
                callConstructor(argc);
            },
            .this_val => {
                // 'this' is the first local (slot 0 of current frame). In sloppy
                // mode (which BotGuard relies on), an unbound `this` — top-level
                // code, eval code, and function calls with no/undefined thisArg —
                // resolves to the global object, NOT undefined. `var O=this||self`
                // and `(function(){...}).call(this)` in the payload depend on
                // top-level `this` being the global.
                const cur = frames[frame_count - 1];
                if (cur.func_id == 0xFFFF) {
                    push(Value.object(global_obj));
                } else {
                    const abs = cur.bp;
                    const tv = if (abs < MAX_STACK) stack[abs] else Value.UNDEFINED;
                    // Sloppy-mode: an undefined/null bound `this` becomes global.
                    if (tv.tag == .undefined or tv.tag == .null_val) {
                        push(Value.object(global_obj));
                    } else {
                        push(tv);
                    }
                }
            },
            .throw_op => {
                const thrown = pop();
                dbg_throw += 1;
                // Record the thrown value for diagnostics: Error objects -> name,
                // strings -> the string, else the tag name.
                if (thrown.tag == .object) {
                    const oi: u32 = thrown.data.obj_idx;
                    const nm = objects.getProperty(oi, values.internString("name"));
                    const ms = objects.getProperty(oi, values.internString("message"));
                    if (nm.tag == .string) {
                        var tb: [96]u8 = undefined;
                        const nms = values.getString(nm.data.str_idx);
                        var tn: usize = @min(nms.len, 40);
                        @memcpy(tb[0..tn], nms[0..tn]);
                        if (ms.tag == .string and tn < 90) {
                            tb[tn] = ':'; tn += 1;
                            const mss = values.getString(ms.data.str_idx);
                            const mn = @min(mss.len, 90 - tn);
                            @memcpy(tb[tn .. tn + mn], mss[0..mn]);
                            tn += mn;
                        }
                        recordThrowMsg(tb[0..tn]);
                    } else recordThrowMsg("<obj throw>");
                } else if (thrown.tag == .string) {
                    recordThrowMsg(values.getString(thrown.data.str_idx));
                } else {
                    recordThrowMsg(@tagName(thrown.tag));
                }
                if (dbg_first_throw_tag == 255) {
                    dbg_first_throw_tag = @intFromEnum(thrown.tag);
                    dbg_first_throw_num = if (thrown.tag == .number) @intFromFloat(thrown.data.number) else -1;
                    if (thrown.tag == .array or thrown.tag == .object) {
                        const ai: u32 = thrown.data.obj_idx;
                        dbg_first_throw_e0 = if (objects.arrayLength(ai) > 0) blk: {
                            const e = objects.getArrayElement(ai, 0);
                            break :blk if (e.tag == .number) @intFromFloat(e.data.number) else -2;
                        } else -3;
                        dbg_first_throw_e1 = if (objects.arrayLength(ai) > 1) blk: {
                            const e = objects.getArrayElement(ai, 1);
                            break :blk if (e.tag == .number) @intFromFloat(e.data.number) else -2;
                        } else -3;
                    }
                }
                throwException(thrown);
            },
            .enter_try => {
                const catch_offset = readU32(bc, &frame.ip);
                const finally_offset = readU32(bc, &frame.ip);
                const protected_end = readU32(bc, &frame.ip);
                dbg_enter_try += 1;
                if (try_count < MAX_TRY_FRAMES) {
                    try_frames[try_count] = .{
                        .catch_ip = catch_offset,
                        .finally_ip = finally_offset,
                        .frame_depth = frame_count,
                        .stack_depth = sp,
                        .start_ip = frame.ip,
                        .end_ip = protected_end,
                    };
                    try_count += 1;
                } else fail("try frame capacity exceeded");
            },
            .leave_try => {
                if (try_count > 0 and try_frames[try_count-1].frame_depth == frame_count) try_count -= 1;
            },
            .enter_catch => {
                push(error_value);
                had_error = false;
            },
            .enter_finally => {
                const end = readU32(bc, &frame.ip);
                if (finally_count == finally_contexts.len) { fail("finally context capacity exceeded"); return false; }
                finally_contexts[finally_count] = .{ .frame_depth = frame_count, .start_ip = frame.ip, .end_ip = end, .action = staged_completion orelse .{}, .statement_completion = frame.eval_completion };
                finally_count += 1;
                staged_completion = null;
            },
            .leave_finally => {
                if (finally_count == 0 or finally_contexts[finally_count-1].frame_depth != frame_count) { fail("unbalanced finally context"); return false; }
                finally_count -= 1;
                const context = finally_contexts[finally_count];
                frame.eval_completion = context.statement_completion;
                completion = frame.eval_completion;
                switch (context.action.kind) {
                    .normal => {},
                    .exception => throwException(context.action.value),
                    .return_value => returnFromFrame(context.action.value),
                    .jump => { sp = context.action.stack_depth; jumpTo(frame, context.action.target); },
                }
            },

            // Iteration (simplified)
            .iter_init => {
                // Pop the object; push an iterator onto the iterator stack.
                const target_val = pop();
                if (iter_count < MAX_ITERS) {
                    var it = IterState{ .valid = true };
                    if (target_val.tag == .object or target_val.tag == .array or target_val.tag == .function) {
                        const oi: u32 = target_val.data.obj_idx;
                        it.obj_idx = oi;
                        it.count = @intCast(objects.enumerateKeys(oi, &it.keys));
                    }
                    iters[iter_count] = it;
                    iter_count += 1;
                }
            },
            .iter_next => {
                const target = readU32(bc, &frame.ip);
                if (iter_count == 0) { jumpTo(frame, target); } else {
                    var it = &iters[iter_count - 1];
                    if (!it.valid or it.pos >= it.count) {
                        jumpTo(frame, target); // exhausted -> exit loop
                    } else {
                        // for-in yields keys (property names / array index strings).
                        const name_idx = it.keys[it.pos];
                        push(Value.string(name_idx));
                        it.pos += 1;
                    }
                }
            },
            .iter_close => { if (iter_count > 0) iter_count -= 1; },

            // Inc/Dec
            .pre_inc => { if (sp > 0) stack[sp - 1] = Value.number(stack[sp - 1].toNumber() + 1); },
            .pre_dec => { if (sp > 0) stack[sp - 1] = Value.number(stack[sp - 1].toNumber() - 1); },
            .post_inc => { if (sp > 0) { push(stack[sp - 2]); stack[sp - 2] = Value.number(stack[sp - 2].toNumber() + 1); } },
            .post_dec => { if (sp > 0) { push(stack[sp - 2]); stack[sp - 2] = Value.number(stack[sp - 2].toNumber() - 1); } },

            .debugger_op => {},
            .set_completion => { frame.eval_completion = pop(); completion = frame.eval_completion; },
            .get_completion => { push(frame.eval_completion); },
            .del_prop => {
                const name_idx = readU16(bc, &frame.ip);
                const obj_val = pop();
                var deleted = true;
                if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function) {
                    deleted = objects.deleteOwnProperty(@intCast(obj_val.data.obj_idx), constToStringIdx(name_idx));
                }
                push(if (deleted) Value.TRUE else Value.FALSE);
            },
            .del_elem => {
                const key = pop();
                const obj_val = pop();
                var deleted = true;
                if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function) {
                    const oi: u32 = @intCast(obj_val.data.obj_idx);
                    // `delete arr[i]` on a real array clears the element; on any
                    // object (incl. numeric key `delete o[5]`) delete the named
                    // property "5" (JS ToPropertyKey) — mirrors get/set which now
                    // treat numeric keys on plain objects as named props.
                    const name = builtins.keyToNameIdx(key);
                    if (operation_aborted) return false;
                    deleted = objects.deleteOwnProperty(oi, name);
                }
                push(if (deleted) Value.TRUE else Value.FALSE);
            },
        }
    return false;
}

/// Synchronously call a function value with up to 3 args and return its result.
/// Used by array iteration methods (forEach/map/filter/reduce) and comparators.
/// Runs a bounded nested execution of the callee's frame(s).
fn invokeBuiltinCallback(fn_val: Value, this_val: Value, args: []const Value) Value {
    if (args.len > 3) return callExportedN(fn_val, this_val, args);
    return callValueSync(fn_val, this_val,
        if (args.len > 0) args[0] else Value.UNDEFINED,
        if (args.len > 1) args[1] else Value.UNDEFINED,
        if (args.len > 2) args[2] else Value.UNDEFINED, @intCast(args.len));
}

fn prepareUserLocals(bp: u16, fobj: u32, actual_count: usize) void {
    const fid = objects.getObject(fobj).func_id;
    const desc = compiler.getFunction(fid);
    const end: usize = @as(usize, bp) + desc.local_count;
    if (end > MAX_STACK or @as(usize, bp) + 1 + actual_count > sp) {
        fail("function local capacity exceeded");
        return;
    }
    var arguments_obj: u32 = objects.NULL_OBJ;
    if (desc.arguments_slot != 0xFFFF) {
        arguments_obj = objects.createObject();
        objects.markArguments(arguments_obj);
        var i: usize = 0;
        while (i < actual_count) : (i += 1) {
            const key = builtins.keyToNameIdx(Value.number(@floatFromInt(i)));
            objects.setProperty(arguments_obj, key, stack[@as(usize, bp) + 1 + i]);
        }
        const length_key = values.internString("length");
        objects.setProperty(arguments_obj, length_key, Value.number(@floatFromInt(actual_count)));
        objects.setEnumerable(arguments_obj, length_key, false);
        if (desc.arguments_mapped) {
            const callee_key = values.internString("callee");
            objects.setProperty(arguments_obj, callee_key, Value.function(fobj));
            objects.setEnumerable(arguments_obj, callee_key, false);
        }
    }
    // Extra supplied arguments must never initialize ordinary local variables.
    // Missing formals and all nonparameter slots begin as undefined.
    var slot: usize = 1;
    while (slot < desc.local_count) : (slot += 1) {
        if (slot > desc.param_count or slot > actual_count) stack[@as(usize, bp) + slot] = Value.UNDEFINED;
    }
    sp = @intCast(end);
    if (arguments_obj == objects.NULL_OBJ) return;
    stack[bp + desc.arguments_slot] = Value.object(arguments_obj);
    if (!desc.arguments_mapped) return;
    var i: usize = @min(actual_count, desc.param_count);
    while (i > 0) {
        i -= 1;
        const name = compiler.funcLocalName(fid, @intCast(i + 1));
        var repeated = false;
        var later = i + 1;
        while (later < desc.param_count) : (later += 1) {
            if (compiler.funcLocalName(fid, @intCast(later + 1)) == name) { repeated = true; break; }
        }
        if (!repeated and name != 0xFFFFFFFF) {
            const key = builtins.keyToNameIdx(Value.number(@floatFromInt(i)));
            objects.bindMappedProperty(arguments_obj, key, @intCast(@as(usize, bp) + i + 1));
        }
    }
}

fn callValueSync(fn_val: Value, this_val: Value, a0: Value, a1: Value, a2: Value, argc: u8) Value {
    if (callbackAborted()) return Value.UNDEFINED;
    const caller = SyncCaller.capture();
    defer { _ = caller.transferred(); }
    if (fn_val.tag != .function) return Value.UNDEFINED;
    const fobj: u32 = fn_val.data.func_idx;
    const obj = objects.getObject(fobj);
    if (obj.obj_type != .function) return Value.UNDEFINED;

    // Native callback: dispatch directly.
    if (obj.func_id >= 0xF000) {
        if (isArrayIterMethod(obj.func_id)) {
            return arrayIterMethod(obj.func_id, this_val, if (argc > 0) a0 else Value.UNDEFINED, if (argc > 1) a1 else Value.UNDEFINED);
        }
        if (builtins.isFnMethod(obj.func_id) or builtins.isVmIntrinsic(obj.func_id)) {
            const args = [_]Value{ a0, a1, a2 };
            return callExportedN(fn_val, this_val, args[0..argc]);
        }
        // A materialized bound function (`f.bind(thisArg,...)`) invoked
        // synchronously (e.g. a register getter defined as
        // `Array.prototype.pop.bind(stack)`): dispatch the target with
        // this=boundThis and boundArgs ++ (a0,a1,a2).
        if (obj.func_id == builtins.N_FN_BOUND) {
            const bt = objects.getProperty(fobj, values.internString("__target__"));
            if (bt.tag != .function) return Value.UNDEFINED;
            const bthis = objects.getProperty(fobj, values.internString("__boundThis__"));
            const bargs_v = objects.getProperty(fobj, values.internString("__boundArgs__"));
            var comb: [64]Value = undefined;
            var cnn: u8 = 0;
            if (bargs_v.tag == .array or bargs_v.tag == .object) {
                const bl = objects.arrayLength(@intCast(bargs_v.data.obj_idx));
                var k: u32 = 0;
                while (k < bl and cnn < 64) : (k += 1) { comb[cnn] = objects.getArrayElement(@intCast(bargs_v.data.obj_idx), k); cnn += 1; }
            }
            if (argc >= 1 and cnn < 64) { comb[cnn] = a0; cnn += 1; }
            if (argc >= 2 and cnn < 64) { comb[cnn] = a1; cnn += 1; }
            if (argc >= 3 and cnn < 64) { comb[cnn] = a2; cnn += 1; }
            const bto = objects.getObject(bt.data.func_idx);
            if (bto.func_id >= 0xF000) {
                if (builtins.nativeIgnoresReceiver(bto.func_id)) {
                    const result = builtins.callNative(bto.func_id, comb[0..cnn], cnn);
                    _ = checkNativeThrow();
                    return result;
                }
                var rc: [65]Value = undefined;
                rc[0] = bthis;
                var q2: u8 = 0;
                while (q2 < cnn and q2 < 64) : (q2 += 1) rc[q2 + 1] = comb[q2];
                const result = builtins.callNative(bto.func_id, rc[0 .. cnn + 1], cnn + 1);
                _ = checkNativeThrow();
                return result;
            }
            return callExportedN(bt, bthis, comb[0..cnn]);
        }
        if (builtins.isFnMethod(obj.func_id) or builtins.isVmIntrinsic(obj.func_id)) return Value.UNDEFINED;
        var na: [4]Value = .{ this_val, a0, a1, a2 };
        const native_args = if (builtins.nativeIgnoresReceiver(obj.func_id)) na[1 .. argc + 1] else na[0 .. argc + 1];
        const result = builtins.callNative(obj.func_id, native_args, @intCast(native_args.len));
        _ = checkNativeThrow();
        return result;
    }

    // User callback: set up a frame [this][a0..] and run until it returns.
    if (frame_count >= MAX_FRAMES) return Value.UNDEFINED;
    const func_desc = compiler.getFunction(obj.func_id);
    const base = sp;
    push(this_val); // slot 0 = this
    if (argc >= 1) push(a0);
    if (argc >= 2) push(a1);
    if (argc >= 3) push(a2);
    const target_depth = frame_count; // frame we're about to push sits above this
    checkFrameOverlap(@intCast(base), obj.func_id);
    ctor_is[frame_count] = false;
    frames[frame_count] = .{ .func_id = obj.func_id, .ip = func_desc.code_start, .bp = base, .closure_obj = fobj };
    frame_count += 1;
    const need = func_desc.local_count;
    prepareUserLocals(base, fobj, argc);
    if (obj.func_id == dbg_entry_watch_func and !dbg_entry_captured) {
        dbg_entry_captured = true;
        dbg_entry_bp = @intCast(base);
        dbg_entry_sp = sp;
        dbg_entry_lc = need;
    }

    // Run until this callee frame (and any it spawns) returns back to target_depth.
    runUntil(target_depth);

    if (caller.transferred()) return Value.UNDEFINED;
    // Result is on TOS (returnFromFrame pushed it in the callee slot region).
    const result = if (sp > base) stack[sp - 1] else Value.UNDEFINED;
    sp = base;
    return result;
}

/// Call a JS function value from host (Sig) code with an arbitrary number of
/// arguments. Used to drive the BotGuard entry point `trayride.a(...)` and the
/// VM-provided snapshot function, which take more args than callValueSync's 3.
/// Returns the function's return value (TOS after it returns).
pub fn callExportedN(fn_val: Value, this_val: Value, args: []const Value) Value {
    if (callbackAborted()) return Value.UNDEFINED;
    const caller = SyncCaller.capture();
    defer { _ = caller.transferred(); }
    if (fn_val.tag != .function) return Value.UNDEFINED;
    const fobj: u32 = fn_val.data.func_idx;
    const obj = objects.getObject(fobj);
    if (obj.obj_type != .function) return Value.UNDEFINED;

    // Native callback: dispatch directly (native funcs read args as a slice).
    if (obj.func_id >= 0xF000) {
        if (isArrayIterMethod(obj.func_id)) {
            return arrayIterMethod(obj.func_id, this_val, if (args.len > 0) args[0] else Value.UNDEFINED, if (args.len > 1) args[1] else Value.UNDEFINED);
        }
        if (builtins.isFnMethod(obj.func_id) or builtins.isVmIntrinsic(obj.func_id)) {
            if (args.len > 255) { fail("intrinsic synchronous argument capacity exceeded"); return Value.UNDEFINED; }
            const base = sp;
            const depth = frame_count;
            push(fn_val);
            for (args) |arg| push(arg);
            if (builtins.isFnMethod(obj.func_id)) fnMethodCall(obj.func_id, fobj, @intCast(args.len), this_val)
            else {
                const saved_direct = eval_is_direct;
                eval_is_direct = false;
                evalIntrinsic(obj.func_id, @intCast(args.len));
                eval_is_direct = saved_direct;
            }
            runUntil(depth);
            if (caller.transferred()) return Value.UNDEFINED;
            const result = if (sp > base) stack[sp-1] else Value.UNDEFINED;
            sp = base;
            return result;
        }
        if (builtins.nativeIgnoresReceiver(obj.func_id)) {
            const result = builtins.callNative(obj.func_id, args, @intCast(@min(args.len, 255)));
            _ = checkNativeThrow();
            return result;
        }
        if (args.len > 255) { fail("native synchronous argument capacity exceeded"); return Value.UNDEFINED; }
        var receiver_args: [256]Value = undefined;
        receiver_args[0] = this_val;
        @memcpy(receiver_args[1..][0..args.len], args);
        const result = builtins.callNative(obj.func_id, receiver_args[0 .. args.len + 1], @intCast(@min(args.len + 1, 255)));
        _ = checkNativeThrow();
        return result;
    }

    // User function: set up a frame [this][arg0..argN] and run until it returns.
    if (frame_count >= MAX_FRAMES) return Value.UNDEFINED;
    const func_desc = compiler.getFunction(obj.func_id);
    const base = sp;
    push(this_val); // slot 0 = this
    for (args) |a| push(a);
    const target_depth = frame_count;
    checkFrameOverlap(@intCast(base), obj.func_id);
    ctor_is[frame_count] = false;
    frames[frame_count] = .{ .func_id = obj.func_id, .ip = func_desc.code_start, .bp = base, .closure_obj = fobj };
    frame_count += 1;
    const need = func_desc.local_count;
    prepareUserLocals(base, fobj, args.len);
    if (obj.func_id == dbg_entry_watch_func and !dbg_entry_captured) {
        dbg_entry_captured = true;
        dbg_entry_bp = @intCast(base);
        dbg_entry_sp = sp;
        dbg_entry_lc = need;
    }

    runUntil(target_depth);

    if (caller.transferred()) return Value.UNDEFINED;
    const result = if (sp > base) stack[sp - 1] else Value.UNDEFINED;
    sp = base;
    return result;
}

/// Run all deferred tasks (setTimeout callbacks) until the queue is empty.
/// BotGuard schedules its VM setup via setTimeout(fn, 0); this must be called
/// after the synchronous entry point returns so those callbacks actually run.
/// Bounded to avoid runaway task loops.
pub fn drainTasks() void {
    drainTasksUntil(.empty);
}

pub const TaskCompletion = enum { empty, setup, snapshot };

/// Stop at the host's awaited callback so later timers cannot run ahead of the
/// next synchronous invocation. This mirrors awaiting setup/snapshot in JS.
pub fn drainTasksUntil(completion_target: TaskCompletion) void {
    var guard: u32 = 0;
    const deadline = builtins.taskClock() + 5000;
    while (!had_error) {
        if (completion_target == .setup and builtins.bg_vm_setup_called) break;
        if (completion_target == .snapshot and builtins.bg_snapshot_result_called) break;
        guard += 1;
        if (guard > 100_000 or builtins.taskClock() >= deadline) break;
        const task = builtins.takeTask(deadline) orelse break;
        _ = callExportedN(task.callback, Value.object(global_obj), task.args[0..task.argc]);
    }
}

/// Create a native-callback function value that JS can invoke. `native_id`
/// must be a host-callback id (>= NATIVE_BASE) handled by builtins.callNative.
pub fn makeNativeFunction(native_id: u16) Value {
    const idx = objects.createFunction(native_id);
    const arity: u8 = switch (native_id) {
        builtins.N_BG_VM_SETUP => 4,
        builtins.N_BG_SNAPSHOT_RESULT => 1,
        builtins.N_BG_TELEMETRY => 3,
        else => 0,
    };
    const key = values.internString("length");
    objects.setProperty(idx, key, Value.number(@floatFromInt(arity)));
    objects.setEnumerable(idx, key, false);
    objects.setWritable(idx, key, false);
    return Value.function(idx);
}

/// Expose the objects module's global lookups to host code (root.sig Phase 6).
pub fn getPropertyValue(obj_idx: u32, name: []const u8) Value {
    return objects.getProperty(obj_idx, values.internString(name));
}

/// Run the interpreter loop until frame_count drops to `until_depth` (the
/// nested call returned) or an error/step-limit occurs.
pub var dbg_hash_n: usize = 0;
pub var dbg_serialized_n: usize = 0;
pub var dbg_serialized_bytes: [65536]u8 = undefined;
pub var dbg_register_fault_depth: usize = 0;
pub var dbg_register_fault_frames: [16]u16 = undefined;
pub var dbg_register_fault_locals: [16][16]Value = undefined;
pub var dbg_factory_n: usize = 0;
pub var dbg_factory_register: u32 = 448;
pub var dbg_factory_rows: [64][9]Value = undefined;
pub var dbg_watch_write_n: usize = 0;
pub var dbg_watch_write_values: [32]Value = undefined;
pub var dbg_watch_write_funcs: [32][3]u16 = undefined;
pub var dbg_watch_write_slots: [32][3][16]Value = undefined;
pub var dbg_ud_n: usize = 0;
pub var dbg_ud_result: [8]Value = undefined;
pub var dbg_ud_slots: [8][16]Value = undefined;
pub var dbg_ud_fields: [8][16]Value = undefined;
pub var dbg_snapshot_cells: [4]Value = undefined;
fn debugUpvalue(frame: CallFrame, name: []const u8) Value {
    for (0..compiler.upvalCount(frame.func_id)) |i| {
        if (!eql(values.getString(compiler.funcUpvalName(frame.func_id, @intCast(i))), name)) continue;
        if (objects.isClosureUpvalClosed(frame.closure_obj, @intCast(i))) return objects.getClosureUpvalClosedVal(frame.closure_obj, @intCast(i));
        const addr = objects.getClosureUpvalAddr(frame.closure_obj, @intCast(i));
        return if (addr < MAX_STACK) stack[addr] else Value.UNDEFINED;
    }
    return Value.UNDEFINED;
}
pub var dbg_hash_capture: usize = 0xFFFFFFFF;
pub var dbg_hash_text_n: usize = 0;
pub var dbg_hash_text: [256]Value = undefined;
pub var dbg_hash_text_at: [256]usize = undefined;
pub var dbg_protocol_n: usize = 0;
pub var dbg_protocol_args: [256][3]Value = undefined;
pub var dbg_protocol_g: [256]usize = undefined;
pub var dbg_register_trace_on: bool = false;
pub var dbg_register_trace_n: usize = 0;
pub var dbg_register_trace_ids: [32768]u16 = undefined;
pub var dbg_register_trace_hash: [32768]usize = undefined;
pub var dbg_register_trace_values: [32768]Value = undefined;
pub var dbg_hash_rows: [8192][6]f64 = undefined;
pub var dbg_hash_stack: [16]u16 = [_]u16{0xFFFF} ** 16;
pub var dbg_encode_n: usize = 0;
pub var dbg_guard_n: usize = 0;
pub var dbg_guard_rows: [64][5]f64 = undefined;
pub var dbg_two_func: u16 = 0xFFFF;
pub var dbg_two_a: Value = Value.UNDEFINED;
pub var dbg_two_b: Value = Value.UNDEFINED;
pub var dbg_two_reg: Value = Value.UNDEFINED;
pub var dbg_ai_ret: Value = Value.UNDEFINED;
pub var dbg_hnum_func: u16 = 0xFFFF;
pub var dbg_hnum_value: f64 = 0;
pub var dbg_hnum_caller: u16 = 0xFFFF;
pub var dbg_fiftysix_n: usize = 0;
pub var dbg_fiftysix_calls: [64][2]u16 = undefined;
pub var dbg_encode_args: [128]Value = undefined;
pub var dbg_encode_x: [128]Value = undefined;
pub var dbg_encode_len: [128]u32 = undefined;
pub var dbg_encode_g: [128]Value = undefined;
pub var dbg_encode_caller: [128]u16 = undefined;
pub var dbg_register_watch: [3]i32 = .{ -1, -1, -1 };
// Optional development observer. Slots include `this` followed by parameters;
// callbacks must not enter JavaScript or modify VM storage. No production sink.
pub var debug_function_entry: ?*const fn (u16, []const Value) void = null;
pub var debug_function_return: ?*const fn (u16, []const Value, Value) void = null;
pub fn debugCallerFunction(depth: usize) u16 {
    return if (depth + 1 < frame_count) frames[frame_count - 2 - depth].func_id else 0xFFFF;
}
pub fn debugCallerSlots(depth: usize) []const Value {
    if (depth + 1 >= frame_count) return &.{};
    const caller = frames[frame_count - 2 - depth];
    const desc = compiler.getFunction(caller.func_id);
    return stack[caller.bp..@min(sp, caller.bp + @as(u32, desc.param_count) + 1)];
}
pub var dbg_register_first: usize = 0;
pub var dbg_register_last: usize = 0;
pub fn dbgRegisterWatch(registers: [3]i32, first: usize, last: usize) void {
    dbg_register_watch = registers;
    dbg_register_first = first;
    dbg_register_last = last;
    dbg_417_n = 0;
    dbg_branch_a = Value.UNDEFINED;
    dbg_branch_b = Value.UNDEFINED;
}
fn dbgHashEntry(frame: *CallFrame) void {
    if (debug_function_entry) |observe| {
        const desc = compiler.getFunction(frame.func_id);
        if (frame.ip == desc.code_start + 1) observe(frame.func_id, stack[frame.bp..@min(sp, frame.bp + @as(u32, desc.param_count) + 1)]);
    }
    if (dbg_gtrace_on and dbg_serialized_n == 0 and frame.ip == compiler.getFunction(frame.func_id).code_start + 1 and startsWith(compiler.funcSourceText(frame.func_id), "function(J,z,Z,b,k,c,l,D,T,H,P,G){{P=0;while(P!=85)") and stack[frame.bp+1].tag == .number and stack[frame.bp+1].data.number == 32) {
        const array = stack[frame.bp+5];
        if (array.tag == .object or array.tag == .array) {
            dbg_serialized_n = @min(objects.arrayLength(array.data.obj_idx), dbg_serialized_bytes.len);
            for (0..dbg_serialized_n) |i| {
                const value = objects.getArrayElement(array.data.obj_idx, @intCast(i));
                dbg_serialized_bytes[i] = if (value.tag == .number) @truncate(toU32(value)) else 0;
            }
        }
    }
    if (!dbg_gtrace_on) return;
    if (dbg_protocol_n < dbg_protocol_args.len and frame.ip == compiler.getFunction(frame.func_id).code_start + 1 and startsWith(compiler.funcSourceText(frame.func_id), "function(J,z,Z,b,k,c,l,D,T,H,P,G,v,q){while(!b.c9")) {
        for (0..3) |i| dbg_protocol_args[dbg_protocol_n][i] = stack[frame.bp + 1 + i];
        dbg_protocol_g[dbg_protocol_n] = dbg_gtrace_n;
        dbg_protocol_n += 1;
    }
    if (dbg_hash_n >= 1300 and dbg_hash_n < 1400 and dbg_hash_text_n < dbg_hash_text.len and frame.ip == compiler.getFunction(frame.func_id).code_start + 1 and startsWith(compiler.funcSourceText(frame.func_id), "function(J,z,Z,b,k,c,l,D,T,H,P,G,v){for(k=(T=J.replace")) {
        dbg_hash_text[dbg_hash_text_n] = stack[frame.bp + 1];
        dbg_hash_text_at[dbg_hash_text_n] = dbg_hash_n;
        dbg_hash_text_n += 1;
    }
    const register_write = if (startsWith(compiler.funcSourceText(frame.func_id), "function(J,z,Z){if(J==57||J==317)")) stack[frame.bp + 1].toNumber() else if (startsWith(compiler.funcSourceText(frame.func_id), "function(f,Q,E){switch(!(f==94||f==401))")) stack[frame.bp + 1].toNumber() else if (startsWith(compiler.funcSourceText(frame.func_id), "function(f,Q,E){switch(!(Q==94||Q==401))")) stack[frame.bp + 2].toNumber() else -1;
    if (register_write == @as(f64, @floatFromInt(dbg_factory_register)) and dbg_gtrace_n >= dbg_register_first and dbg_gtrace_n <= dbg_register_last and frame.ip == compiler.getFunction(frame.func_id).code_start+1 and dbg_watch_write_n < dbg_watch_write_values.len) {
        const row = dbg_watch_write_n;
        dbg_watch_write_values[row] = stack[frame.bp+3];
        for (0..3) |i| {
            if (frame_count <= i+1) { dbg_watch_write_funcs[row][i] = 0xFFFF; continue; }
            const caller = frames[frame_count-2-i]; dbg_watch_write_funcs[row][i] = caller.func_id;
            for (0..16) |j| dbg_watch_write_slots[row][i][j] = if (caller.bp+j < MAX_STACK) stack[caller.bp+j] else Value.UNDEFINED;
        }
        dbg_watch_write_n += 1;
    }
    if (dbg_register_trace_on and dbg_hash_n >= 1313 and dbg_hash_n < 1400 and dbg_register_trace_n < dbg_register_trace_ids.len and frame.ip == compiler.getFunction(frame.func_id).code_start + 1 and register_write >= 0 and register_write <= 65535) {
        const value = stack[frame.bp + 3];
        if (value.tag != .object and value.tag != .array and value.tag != .function) {
            dbg_register_trace_ids[dbg_register_trace_n] = @intFromFloat(register_write);
            dbg_register_trace_hash[dbg_register_trace_n] = dbg_hash_n;
            dbg_register_trace_values[dbg_register_trace_n] = value;
            dbg_register_trace_n += 1;
        }
    }
    if (dbg_417_n < 32 and frame.ip == compiler.getFunction(frame.func_id).code_start + 1 and register_write >= 0 and (register_write == dbg_register_watch[0] or register_write == dbg_register_watch[1] or register_write == dbg_register_watch[2]) and dbg_gtrace_n >= dbg_register_first and dbg_gtrace_n <= dbg_register_last) {
        dbg_417_values[dbg_417_n] = stack[frame.bp + 3];
        dbg_417_registers[dbg_417_n] = register_write;
        dbg_417_g[dbg_417_n] = dbg_gtrace_n;
        const state = if (startsWith(compiler.funcSourceText(frame.func_id), "function(f,Q,E){switch(!(Q==94||Q==401))")) stack[frame.bp + 1] else stack[frame.bp + 2];
        const bank = objects.getProperty(state.data.obj_idx, values.internString("o"));
        dbg_94_bank[dbg_417_n] = bank;
        dbg_94_cell[dbg_417_n] = objects.getArrayElement(bank.data.obj_idx, 94);
        if (register_write == 153 and dbg_gtrace_n > 20000 and dbg_gtrace_n < 23000 and frame_count > 1) {
            const caller = frames[frame_count - 2];
            dbg_property_receiver = stack[caller.bp + 3];
            dbg_property_key = stack[caller.bp + 2];
        }
        dbg_417_funcs[dbg_417_n] = if (frame_count > 1) frames[frame_count - 2].func_id else 0xFFFF;
        dbg_417_n += 1;
    }
    if (frame.func_id == 302 and frame.ip == compiler.getFunction(302).code_start + 1 and dbg_encode_n < 128) {
        dbg_encode_args[dbg_encode_n] = stack[frame.bp + 1]; dbg_encode_x[dbg_encode_n] = stack[frame.bp + 2]; dbg_encode_g[dbg_encode_n] = stack[frame.bp + 3];
        dbg_encode_caller[dbg_encode_n] = if (frame_count > 1) frames[frame_count-2].func_id else 0xFFFF;
        dbg_encode_len[dbg_encode_n] = objects.arrayLength(stack[frame.bp+2].data.obj_idx); dbg_encode_n += 1;
    }
    const hash_source = compiler.funcSourceText(frame.func_id);
    if ((!startsWith(hash_source, "function(J,z,Z,b,k){switch(!(J.length==3))") and !startsWith(hash_source, "function(b,x,g,Y,L){if(b.length==3)") and !startsWith(hash_source, "function(f,Q,E,T,D){if(f.length==3)")) or frame.ip != compiler.getFunction(frame.func_id).code_start + 1 or dbg_hash_n >= 8192) return;
    const b = stack[frame.bp + 1];
    const x = stack[frame.bp + 2];
    if ((b.tag != .object and b.tag != .array) or (x.tag != .object and x.tag != .array) or objects.arrayLength(b.data.obj_idx) != 3) return;
    if (dbg_hash_n == 0) {
        for (0..@min(frame_count, 16)) |i| dbg_hash_stack[i] = frames[frame_count - 1 - i].func_id;
    }
    if (dbg_hash_n == dbg_hash_capture) {
        dbg_gtrace_cap_n = @min(frame_count, dbg_gtrace_cap_slots.len);
        for (0..dbg_gtrace_cap_n) |i| {
            const captured = frames[frame_count - 1 - i];
            dbg_gtrace_cap_func[i] = captured.func_id;
            dbg_gtrace_cap_ip[i] = captured.ip;
            for (0..16) |j| dbg_gtrace_cap_slots[i][j] = if (captured.bp + j < MAX_STACK) stack[captured.bp + j] else Value.UNDEFINED;
        }
    }
    for (0..3) |i| {
        dbg_hash_rows[dbg_hash_n][i] = objects.getArrayElement(b.data.obj_idx, @intCast(i)).toNumber();
        dbg_hash_rows[dbg_hash_n][i+3] = objects.getArrayElement(x.data.obj_idx, @intCast(i)).toNumber();
    }
    dbg_hash_n += 1;
}
fn runUntil(until_depth: u16) void {
    var guard: u64 = 0;
    while (frame_count > until_depth and !had_error) {
        if (values.exhausted) { fail("string arena exhausted"); return; }
        guard += 1;
        // Loop-hotspot capture: once we're clearly stuck (near the limit),
        // record which (func,ip) sites execute so the diagnostic can report
        // the exact spinning bytecode instead of a generic step-limit.
        if (guard >= execution_limit - @min(execution_limit, 1_000_000)) {
            if (frame_count > 0) {
                const f = &frames[frame_count - 1];
                dbgHotRecord(f.func_id, f.ip, @intCast(frame_count));
            }
        }
        if (guard >= execution_limit) { fail("nested step limit"); return; }
        if (frame_count == 0) break;
        const bc = compiler.getBytecode();
        var frame = &frames[frame_count - 1];
        if (frame.ip >= bc.len) break;
        if (dbg_callrec_on and frame.func_id == dbg_bigfn_id and frame.ip > dbg_bigfn_maxip) dbg_bigfn_maxip = frame.ip;
        if (objects.dbg_track_active) {
            objects.dbg_active_func = frame.func_id; objects.dbg_active_ip = frame.ip;
            const fc = frame_count;
            objects.dbgSetFrameStack(
                if (fc >= 1) frames[fc - 1].func_id else 0xFFFF,
                if (fc >= 2) frames[fc - 2].func_id else 0xFFFF,
                if (fc >= 3) frames[fc - 3].func_id else 0xFFFF,
                if (fc >= 4) frames[fc - 4].func_id else 0xFFFF,
                if (fc >= 5) frames[fc - 5].func_id else 0xFFFF,
                if (fc >= 6) frames[fc - 6].func_id else 0xFFFF,
                @intCast(@min(fc, 6)));
        }
        const op: Op = @enumFromInt(bc[frame.ip]);
        frame.ip += 1;
        if (execOne(op, bc, frame)) break; // halt
    }
}

// ── Call / Return ──

/// Drop a pending completion only when control actually leaves its finally.
/// A callback or a catch nested inside the body preserves the outer action.
fn discardFinallyOutside(depth: u16, target: u32) void {
    while (finally_count > 0) {
        const context = finally_contexts[finally_count-1];
        if (context.frame_depth < depth) break;
        if (context.frame_depth == depth and target >= context.start_ip and target < context.end_ip) break;
        finally_count -= 1;
    }
}

/// Every branch uses lexical protected-region bounds, so break/continue and
/// labelled jumps cannot leave dead catch handlers on the exception stack.
fn jumpTo(frame: *CallFrame, target: u32) void {
    discardFinallyOutside(frame_count, target);
    const destination_sp = sp;
    while (try_count > 0 and try_frames[try_count-1].frame_depth == frame_count) {
        const handler = try_frames[try_count-1];
        if (target >= handler.start_ip and target < handler.end_ip) break;
        try_count -= 1;
        if (handler.finally_ip != 0) {
            staged_completion = .{ .kind = .jump, .target = target, .stack_depth = destination_sp };
            sp = handler.stack_depth;
            frame.ip = handler.finally_ip;
            return;
        }
    }
    frame.ip = target;
}

fn returnThroughFinally(result: Value) bool {
    discardFinallyOutside(frame_count, 0xFFFFFFFF);
    while (try_count > 0 and try_frames[try_count-1].frame_depth == frame_count) {
        try_count -= 1;
        const handler = try_frames[try_count];
        if (handler.finally_ip != 0) {
            staged_completion = .{ .kind = .return_value, .value = result };
            sp = handler.stack_depth;
            frames[frame_count-1].ip = handler.finally_ip;
            return true;
        }
    }
    return false;
}

fn callFunction(argc: u8) void {
    if (sp < argc + 1) { fail("call: stack underflow"); return; }

    const callee_val = stack[sp - 1 - argc];

    // Check if it's a native builtin
    if (callee_val.tag == .function) {
        const obj_idx: u32 = callee_val.data.func_idx;
        const obj = objects.getObject(obj_idx);

        if (obj.obj_type == .function) {
            const func_desc = compiler.getFunction(obj.func_id);

            // VM intrinsics (eval / Function) need compiler+VM re-entrancy and
            // are handled directly here rather than via callNative.
            if (builtins.isVmIntrinsic(obj.func_id)) {
                evalIntrinsic(obj.func_id, argc);
                return;
            }

            // Function.prototype.call/apply/bind bound-invokers.
            if (builtins.isFnMethod(obj.func_id)) {
                fnMethodCall(obj.func_id, obj_idx, argc, null);
                return;
            }

            // Check if this is a native function (func_id >= 0xF000)
            if (obj.func_id >= 0xF000) {
                // Native call
                dbg_native_calls += 1;
                if (dbg_callrec_on) dbgRecordNative(obj.func_id);
                // Plain calls have an undefined receiver. Receiver-aware native
                // adapters still need that slot when a method is detached into
                // a variable (e.g. `const create = Object.create; create(proto)`).
                // Reuse the consumed callee slot so reentrant callbacks retain
                // stable arguments without an additional temporary arena.
                const native_args = if (builtins.nativeIgnoresReceiver(obj.func_id)) stack[sp - argc .. sp] else blk: {
                    stack[sp - argc - 1] = Value.UNDEFINED;
                    break :blk stack[sp - argc - 1 .. sp];
                };
                const result = builtins.callNative(obj.func_id, native_args, @intCast(@min(native_args.len, 255)));
                if (operation_aborted) return;
                sp -= (argc + 1);
                if (checkNativeThrow()) return;
                push(result);
                return;
            }

            // Register-trace: log calls to the Q reader and the wU writer so the
            // ordered (op, register-idx, value-kind) sequence can be diffed
            // against the jsdom oracle (ref_regtrace.txt). Q(b,x)=read x.Y[b];
            // wU(b,x,g)=write. Func ids are pinned-deterministic and passed in via
            // dbg_rt_qfunc / dbg_rt_wufunc.
            // Discovery mode: log (func_id, arg0) for ALL user calls with a
            // numeric arg0, to find which func reads register 184 (the dispatch
            // reader = jsdom's Q equivalent).
            if (dbg_rtdisc_on and dbg_rtdisc_n < dbg_rtdisc_max and argc >= 1) {
                const a0 = stack[sp - argc];
                if (a0.tag == .number) {
                    dbg_rtdisc_func[dbg_rtdisc_n] = obj.func_id;
                    dbg_rtdisc_reg[dbg_rtdisc_n] = @intFromFloat(a0.data.number);
                    dbg_rtdisc_n += 1;
                }
            }
            // Multi-reader trace: tag each read by which reader func (R=181 dispatch,
            // D=177 data reader, W=12 writer) so the full divergence is visible.
            // Q363 return-value capture: mark when the Q reader (func 182) is
            // called with arg0==363, so the return hook can log its create() result.
            if (dbg_q363_on and obj.func_id == 182 and argc >= 1) {
                const a0q = stack[sp - argc];
                dbg_q363_pending = (a0q.tag == .number and @as(i32, @intFromFloat(a0q.data.number)) == 363);
                // On the FIRST Q(363), snapshot the bank object index + the cell so
                // we can inspect why reg-363's create() returns an object (should be undef).
                if (dbg_q363_pending and !dbg_q363_bank_done and argc >= 2) {
                    dbg_q363_bank_done = true;
                    const xq = stack[sp - argc + 1];
                    if (xq.tag == .object or xq.tag == .array) dbg_q363_bank_obj = xq.data.obj_idx;
                }
            }
            // PP entry-capture: at the Nth call to PP (func dbg_pp_func), snapshot
            // the args AT ENTRY (before PP mutates its param slots) + the eventual
            // handled by the return hook. Here we count calls and record entry args.
            if (dbg_pp_on and obj.func_id == dbg_pp_func) {
                if (dbg_pp_entry_n == dbg_pp_capture_at and !dbg_pp_entry_done) {
                    dbg_pp_entry_done = true;
                    // args: stack[sp-argc .. sp] = arg0(b),arg1(x),arg2(g)
                    if (argc >= 1) { const a = stack[sp - argc]; dbg_pp_e_b_tag = @intFromEnum(a.tag); dbg_pp_e_b_num = if (a.tag == .number) a.data.number else -1; }
                    if (argc >= 3) { const a = stack[sp - argc + 2]; dbg_pp_e_g_num = if (a.tag == .number) a.data.number else -1; }
                    dbg_pp_e_argc = argc;
                }
                dbg_pp_entry_n += 1;
            }
            // PP-discovery: record the CALLER func whenever the Q-reader(182) is
            // invoked with arg0==184 (the PC read). PP is the dominant such caller.
            if (dbg_ppdisc_on and obj.func_id == 182 and argc >= 1) {
                const a0p = stack[sp - argc];
                if (a0p.tag == .number and @as(i32, @intFromFloat(a0p.data.number)) == 184 and frame_count > 0) {
                    const caller_fid = frames[frame_count - 1].func_id;
                    if (caller_fid < dbg_ppdisc_hist.len) dbg_ppdisc_hist[caller_fid] += 1;
                }
            }
            if (dbg_rt_multi and dbg_rt_n < dbg_rt_max and argc >= 1) {
                const a0m = stack[sp - argc];
                if (a0m.tag == .number) {
                    var opc: u8 = 0;
                    if (obj.func_id == 181) opc = 'R' else if (obj.func_id == 177) opc = 'D' else if (obj.func_id == 12) opc = 'W';
                    if (opc != 0) {
                        dbg_rt_op[dbg_rt_n] = opc;
                        dbg_rt_reg[dbg_rt_n] = @intFromFloat(a0m.data.number);
                        // For writer (12), log g's kind (arg2); for readers, the raw cell kind.
                        if (opc == 'W' and argc >= 3) {
                            dbg_rt_kind[dbg_rt_n] = dbgKindOf(stack[sp - argc + 2]);
                        } else if (argc >= 2) {
                            const xv = stack[sp - argc + 1];
                            var ck: u8 = 255;
                            if (xv.tag == .object or xv.tag == .array) {
                                const yv = objects.getProperty(xv.data.obj_idx, values.internString("Y"));
                                if (yv.tag == .object or yv.tag == .array) ck = dbgKindOf(getElemFromValue(yv, a0m));
                            }
                            dbg_rt_kind[dbg_rt_n] = ck;
                        } else dbg_rt_kind[dbg_rt_n] = 255;
                        dbg_rt_n += 1;
                    }
                }
            }
            if (dbg_rt_on and dbg_rt_n < dbg_rt_max) {
                if (obj.func_id == dbg_rt_qfunc and argc >= 1) {
                    const bv = stack[sp - argc]; // arg0 = b
                    // Capture the frame stack at the Nth Q-read (the divergence point),
                    // plus the value of register 363 (the decode-state the dispatch
                    // branches on) read via the bank at arg1.
                    if (bv.tag == .number and dbg_rt_n == dbg_rt_capture_at and !dbg_rt_captured) {
                        dbg_rt_captured = true;
                        dbg_rt_cap_reg = @intFromFloat(bv.data.number);
                        dbg_rt_cap_framen = @min(frame_count, dbg_rt_cap_func.len);
                        var cfi: usize = 0;
                        while (cfi < dbg_rt_cap_framen) : (cfi += 1) {
                            const cf = frames[frame_count - 1 - cfi];
                            dbg_rt_cap_func[cfi] = cf.func_id;
                            dbg_rt_cap_ip[cfi] = cf.ip;
                        }
                    }
                    if (bv.tag == .number) {
                        // Read x.Y[b] to log the raw cell kind (arg1 = x).
                        var cellkind: u8 = 255;
                        if (argc >= 2) {
                            const xv = stack[sp - argc + 1];
                            if (xv.tag == .object or xv.tag == .array) {
                                const yv = objects.getProperty(xv.data.obj_idx, values.internString("Y"));
                                if (yv.tag == .object or yv.tag == .array) {
                                    const cell = getElemFromValue(yv, bv);
                                    cellkind = dbgKindOf(cell);
                                }
                            }
                        }
                        dbg_rt_op[dbg_rt_n] = 'Q';
                        dbg_rt_reg[dbg_rt_n] = @intFromFloat(bv.data.number);
                        dbg_rt_kind[dbg_rt_n] = cellkind;
                        // Mark this Q-read entry as pending its return value (captured
                        // at returnFromFrame). Q reads don't nest, so a single pending
                        // slot is safe.
                        dbg_rt_qret_pending = true;
                        dbg_rt_qret_idx = dbg_rt_n;
                        dbg_rt_val[dbg_rt_n] = -1234567890123.0;
                        dbg_rt_e0[dbg_rt_n] = -1234567890123.0;
                        dbg_rt_e1[dbg_rt_n] = -1234567890123.0;
                        dbg_rt_n += 1;
                    }
                } else if (obj.func_id == dbg_rt_wufunc and argc >= 3) {
                    const bv = stack[sp - argc];      // arg0 = b
                    const gv = stack[sp - argc + 2];  // arg2 = g (value written)

                    // Capture frame stack at the Nth write to the watched register.
                    if (bv.tag == .number and @as(i32, @intFromFloat(bv.data.number)) == dbg_wcap_reg) {
                        dbg_wcap_seen += 1;
                        if (dbg_wcap_seen == dbg_wcap_nth and !dbg_wcap_done) {
                            dbg_wcap_done = true;
                            dbg_wcap_gtag = @intFromEnum(gv.tag);
                            // Capture the CALLER frame's (func 161's) local slots
                            // numeric values (wU's frame not yet pushed), so we can
                            // see local3 (the reg index read) and local5 (receiver).
                            if (frame_count >= 1) {
                                const caller = frames[frame_count - 1];
                                var li: usize = 0;
                                while (li < 8 and caller.bp + li < MAX_STACK) : (li += 1) {
                                    const sv = stack[caller.bp + li];
                                    dbg_wcap_caller_num[li] = if (sv.tag == .number) sv.data.number else -999999;
                                    dbg_wcap_caller_tag[li] = @intFromEnum(sv.tag);
                                }
                                dbg_wcap_caller_func = caller.func_id;
                                // L5 = the object receiver; L4 = the string key.
                                // Record L5's objidx, L4's string, and whether L5
                                // (or its proto chain) has that key.
                                const l5 = stack[caller.bp + 5];
                                const l4 = stack[caller.bp + 4];
                                if (l5.tag == .object or l5.tag == .array) {
                                    dbg_wcap_l5_objidx = l5.data.obj_idx;
                                    dbg_wcap_l5_type = @intFromEnum(objects.objTypeOf(l5.data.obj_idx));
                                }
                                if (l4.tag == .string) {
                                    const ks = values.getString(l4.data.str_idx);
                                    const kk = @min(ks.len, dbg_wcap_l4key.len);
                                    @memcpy(dbg_wcap_l4key[0..kk], ks[0..kk]);
                                    dbg_wcap_l4key_len = kk;
                                    if (l5.tag == .object or l5.tag == .array) {
                                        const gv2 = getElemFromValue(l5, l4);
                                        dbg_wcap_l5key_valtag = @intFromEnum(gv2.tag);
                                        dbg_wcap_l5_hasown = if (objects.hasOwnProperty(l5.data.obj_idx, l4.data.str_idx)) 1 else 0;
                                    }
                                }
                            }
                            dbg_wcap_framen = @min(frame_count, dbg_wcap_func.len);
                            var wfi: usize = 0;
                            while (wfi < dbg_wcap_framen) : (wfi += 1) {
                                const wf = frames[frame_count - 1 - wfi];
                                dbg_wcap_func[wfi] = wf.func_id;
                                dbg_wcap_ip[wfi] = wf.ip;
                            }
                        }
                    }
                    if (bv.tag == .number) {
                        dbg_rt_op[dbg_rt_n] = 'W';
                        dbg_rt_reg[dbg_rt_n] = @intFromFloat(bv.data.number);
                        // For strings, encode length as 100+min(len,150) so the diff
                        // reveals truncated-string divergences (empty body → short).
                        dbg_rt_kind[dbg_rt_n] = if (gv.tag == .string)
                            @intCast(100 + @min(values.getString(gv.data.str_idx).len, 150))
                        else dbgKindOf(gv);
                        // Full numeric value written (for numbers); NaN sentinel otherwise.
                        dbg_rt_val[dbg_rt_n] = if (gv.tag == .number) gv.data.number else -1234567890123.0;
                        dbg_rt_n += 1;
                    }
                }
            }
            // User function call
            if (argc == 3 and dbg_encode_n <= 65 and dbg_fiftysix_n < 64) {
                const aa = stack[sp-argc]; const ab = stack[sp-argc+1];
                if ((aa.tag == .number and aa.data.number == 56) or (ab.tag == .number and ab.data.number == 56)) {
                    dbg_fiftysix_calls[dbg_fiftysix_n] = .{ obj.func_id, if (frame_count > 0) frames[frame_count-1].func_id else 0xFFFF };
                    dbg_fiftysix_n += 1;
                }
            }
            dbg_user_calls += 1;
            if (dbg_callhist_on and obj.func_id < dbg_callhist.len) dbg_callhist[obj.func_id] += 1;
            if (obj.func_id < dbg_fidhist.len) dbg_fidhist[obj.func_id] += 1;
            if (obj.func_id < dbg_fidhist_all.len) dbg_fidhist_all[obj.func_id] += 1;
            if (dbg_callrec_on) {
                const lc = compiler.getFunction(obj.func_id).param_count;
                if (lc >= dbg_bigfn_locals) {
                    if (obj.func_id != dbg_bigfn_id) { dbg_bigfn_id = obj.func_id; dbg_bigfn_locals = lc; dbg_bigfn_entries = 0; dbg_bigfn_maxip = 0; dbg_bigfn_retok = 0; }
                    dbg_bigfn_entries += 1;
                }
            }
            if (dbg_callrec_on and dbg_callrec_n < dbg_callrec_names.len) {
                dbg_callrec_names[dbg_callrec_n] = last_lookup_name;
                // arg0 is the first argument (stack[sp-argc]); record if numeric.
                if (argc >= 1 and sp >= argc) {
                    const a0 = stack[sp - argc];
                    dbg_callrec_arg0[dbg_callrec_n] = if (a0.tag == .number) @intFromFloat(a0.data.number) else -999999;
                } else dbg_callrec_arg0[dbg_callrec_n] = -999999;
                dbg_callrec_n += 1;
            }
            if (frame_count >= MAX_FRAMES) { fail("call stack overflow"); return; }

            // Frame layout matches the compiler's local slots:
            //   slot 0 = callee/this, slots 1..argc = arguments.
            // The callee value sits at sp-1-argc, so bp points there.
            const new_bp = sp - 1 - argc;
            checkFrameOverlap(@intCast(new_bp), obj.func_id);
            ctor_is[frame_count] = false; // plain call, not a constructor
            // JS sloppy-mode plain call: `this` = the global object (NOT the
            // callee). Slot 0 currently holds the callee function value; the
            // frame no longer needs it (func_id is stored on the frame), so
            // rebind slot 0 to the global object. BotGuard's register-machinery
            // helpers do `J(n, this)` and expect `this` to be a usable object;
            // leaving the callee function there made `this.v` undefined -> the
            // register bank read failed and the interpreter took a degenerate
            // path. Methods (call_method) set slot 0 = receiver separately.
            if (new_bp < MAX_STACK) stack[new_bp] = Value.object(global_obj);
            if (obj.func_id == dbg_ostate_func) {
                // Record the u (slot 1 = first param) of this O call.
                const u_abs = new_bp + 1;
                const uv2 = if (u_abs < MAX_STACK and u_abs < sp) stack[u_abs] else Value.UNDEFINED;
                recordOCall(if (uv2.tag == .number) uv2.data.number else -77777);
            }
            frames[frame_count] = .{
                .func_id = obj.func_id,
                .ip = func_desc.code_start,
                .bp = @intCast(new_bp),
                .closure_obj = obj_idx,
            };
            frame_count += 1;

            // Extend stack so all declared local slots exist (this + params +
            // any additional locals declared in the body).
            const locals_needed = func_desc.local_count;
            prepareUserLocals(@intCast(new_bp), obj_idx, argc);
            // Count all calls to the J-log func (register read); capture the
            // FIRST call whose bank (slot 2) is NOT an object (the anomaly), with
            // its call index, n, bank tag, and caller.
            if (obj.func_id == dbg_jlog_func) {
                dbg_jlog_total += 1;
                const n_abs = new_bp + 1;
                const s_abs = new_bp + 2;
                const nv = if (n_abs < MAX_STACK and n_abs < sp) stack[n_abs] else Value.UNDEFINED;
                const sv = if (s_abs < MAX_STACK and s_abs < sp) stack[s_abs] else Value.UNDEFINED;
                if (dbg_jlog_n < 40) {
                    dbg_jlog_n_arr[dbg_jlog_n] = if (nv.tag == .number) @intFromFloat(@min(nv.data.number, 999999)) else 0xFFFFFFFF;
                    dbg_jlog_s_tag[dbg_jlog_n] = @intFromEnum(sv.tag);
                    dbg_jlog_n += 1;
                }
                if (!dbg_jbad_captured and sv.tag != .object and sv.tag != .array) {
                    dbg_jbad_captured = true;
                    dbg_jbad_callidx = dbg_jlog_total;
                    dbg_jbad_n = if (nv.tag == .number) @intFromFloat(@min(nv.data.number, 999999)) else 0xFFFFFFFF;
                    dbg_jbad_s_tag = @intFromEnum(sv.tag);
                    if (frame_count >= 2) { dbg_jbad_caller_func = frames[frame_count - 2].func_id; dbg_jbad_caller_ip = frames[frame_count - 2].ip; }
                }
            }
            if (obj.func_id == dbg_entry_watch_func and !dbg_entry_captured) {
                // When watching the register-read J, only capture the entry
                // where the bank (param slot 2) is UNDEFINED — the anomaly.
                const slot2_undef = (new_bp + 2 < sp) and (stack[new_bp + 2].tag == .undefined);
                if (!dbg_entry_watch_need_undef2 or slot2_undef) {
                    dbg_entry_captured = true;
                    dbg_entry_bp = @intCast(new_bp);
                    dbg_entry_sp = sp;
                    dbg_entry_lc = locals_needed;
                    dbg_entry_via_call = false;
                    if (frame_count >= 2) { dbg_entry_caller_func = frames[frame_count - 2].func_id; dbg_entry_caller_ip = frames[frame_count - 2].ip; }
                    captureEntryParams(@intCast(new_bp));
                    captureCalleeProvenance(argc, callee_val, obj_idx, obj.func_id);
                }
            }
            // ── FH (func 96) entry trace: capture all 6 params + caller on FIRST entry.
            if (obj.func_id == 96 and !dbg_fhentry_done) {
                dbg_fhentry_done = true;
                dbg_fhentry_argc = argc;
                if (frame_count >= 2) { dbg_fhentry_caller = frames[frame_count - 2].func_id; dbg_fhentry_caller_ip = frames[frame_count - 2].ip; }
                var pp: usize = 0;
                while (pp < 7) : (pp += 1) {
                    const a = new_bp + 1 + pp;
                    const v = if (a < MAX_STACK and a < sp) stack[a] else Value.UNDEFINED;
                    dbg_fhentry_tags[pp] = @intFromEnum(v.tag);
                    dbg_fhentry_nums[pp] = if (v.tag == .number) v.data.number else -987654.0;
                    dbg_fhentry_objs[pp] = if (v.tag == .object or v.tag == .array or v.tag == .function) v.data.obj_idx else 0xFFFFFFFF;
                }
            }
            if (obj.func_id == dbg_dec_op95_id) dbg_dec_op95_entries += 1;
            // Count v(func113) entries and how many read reg 394 (slot bp+2 == 394).
            if (obj.func_id == 113) {
                dbg_v113_total += 1;
                const x2 = new_bp + 2;
                const xv2 = if (x2 < MAX_STACK and x2 < sp) stack[x2] else Value.UNDEFINED;
                if (xv2.tag == .number) {
                    if (xv2.data.number == 394) dbg_v113_reg394 += 1;
                    if (dbg_v113_first_x < 0 and dbg_v113_total <= 1) dbg_v113_first_x = xv2.data.number;
                }
            }
            // Count func-142 (op95) first-dispatch PP position proxy (reads so far via total Q184).
            if (obj.func_id == 142 and dbg_op95_first_v113 == 0) dbg_op95_first_v113 = dbg_v113_total + 1;
            // ── Reg-writer func-25 entry capture: when x(slot2)==363, record the
            // seed g(slot3) array + the CALLER (who computed the seed) + its ip.
            if (obj.func_id == dbg_rw_id and dbg_rw_n < 32) {
                const x_abs = new_bp + 2;
                const xv = if (x_abs < MAX_STACK and x_abs < sp) stack[x_abs] else Value.UNDEFINED;
                if (xv.tag == .number and xv.data.number == dbg_rw_regidx) {
                    const g_abs = new_bp + 3;
                    const gv = if (g_abs < MAX_STACK and g_abs < sp) stack[g_abs] else Value.UNDEFINED;
                    const j = dbg_rw_n;
                    dbg_rw_gtag[j] = @intFromEnum(gv.tag);
                    if (gv.tag == .array or gv.tag == .object) {
                        const gi = gv.data.obj_idx;
                        dbg_rw_gobj[j] = gi;
                        dbg_rw_e0[j] = blk: { const e = objects.getArrayElement(gi, 0); break :blk if (e.tag == .number) e.data.number else -987654.0; };
                        dbg_rw_e1[j] = blk: { const e = objects.getArrayElement(gi, 1); break :blk if (e.tag == .number) e.data.number else -987654.0; };
                        dbg_rw_e2[j] = blk: { const e = objects.getArrayElement(gi, 2); break :blk if (e.tag == .number) e.data.number else -987654.0; };
                    } else if (gv.tag == .number) dbg_rw_e0[j] = gv.data.number;
                    dbg_rw_caller[j] = if (frame_count >= 2) frames[frame_count - 2].func_id else 0xFFFF;
                    dbg_rw_caller_ip[j] = if (frame_count >= 2) frames[frame_count - 2].ip else 0;
                    // Capture the caller (func300) locals A(slot4) and V(slot3) —
                    // A = the register index G(w,27) selecting the seed register.
                    if (frame_count >= 2) {
                        const cbp = frames[frame_count - 2].bp;
                        const a_abs = cbp + 4; const v_abs = cbp + 3;
                        const av = if (a_abs < MAX_STACK) stack[a_abs] else Value.UNDEFINED;
                        const vv = if (v_abs < MAX_STACK) stack[v_abs] else Value.UNDEFINED;
                        dbg_rw_callerA[j] = if (av.tag == .number) av.data.number else -987654.0;
                        dbg_rw_callerV_tag[j] = @intFromEnum(vv.tag);
                        dbg_rw_callerV_obj[j] = if (vv.tag == .object or vv.tag == .array or vv.tag == .function) vv.data.obj_idx else 0xFFFFFFFF;
                    }
                    dbg_rw_n += 1;
                }
            }
            // ── Cell-ctor l(b,x,g,Y,L,F) capture: when F(slot6)==363, record g(slot3)
            // tag/value — the seed passed to the reg-363 cell. Capture ALL (ring).
            if (obj.func_id == dbg_lc_id and dbg_lc_n < 64) {
                const f_abs = new_bp + 6;
                const fv = if (f_abs < MAX_STACK and f_abs < sp) stack[f_abs] else Value.UNDEFINED;
                if (fv.tag == .number and fv.data.number == dbg_lc_regidx) {
                    const g_abs = new_bp + 3;
                    const gv = if (g_abs < MAX_STACK and g_abs < sp) stack[g_abs] else Value.UNDEFINED;
                    const j = dbg_lc_n;
                    dbg_lc_gtag[j] = @intFromEnum(gv.tag);
                    dbg_lc_gnum[j] = if (gv.tag == .number) gv.data.number else -987654.0;
                    dbg_lc_gobj[j] = if (gv.tag == .object or gv.tag == .array or gv.tag == .function) gv.data.obj_idx else 0xFFFFFFFF;
                    dbg_lc_caller[j] = if (frame_count >= 2) frames[frame_count - 2].func_id else 0xFFFF;
                    dbg_lc_n += 1;
                }
            }
            // ── Q(363) cell-identity trace: at Q (func 182) entry with b(param1)==363,
            // capture the cell obj = x.Y[363] (x=param2) so we see when reg-363's
            // CELL is replaced (the write that changes the seed).
            if (obj.func_id == 182 and dbg_q363cell_n < 1024) {
                const b_abs = new_bp + 1;
                const bv = if (b_abs < MAX_STACK and b_abs < sp) stack[b_abs] else Value.UNDEFINED;
                if (bv.tag == .number and bv.data.number == 363) {
                    const x_abs = new_bp + 2;
                    const xv = if (x_abs < MAX_STACK and x_abs < sp) stack[x_abs] else Value.UNDEFINED;
                    var cell: u32 = 0xFFFFFFFF;
                    if (xv.tag == .object or xv.tag == .array) {
                        const yv = objects.getProperty(xv.data.obj_idx, values.internString("Y"));
                        if (yv.tag == .object or yv.tag == .array) {
                            const cv = objects.getArrayElement(yv.data.obj_idx, 363);
                            if (cv.tag == .object or cv.tag == .array or cv.tag == .function) cell = cv.data.obj_idx;
                        }
                    }
                    dbg_q363cell[dbg_q363cell_n] = cell;
                    dbg_q363cell_n += 1;
                }
            }
            // ── wU(363,x,g) write capture: record each write to register 363.
            if (obj.func_id == dbg_wu_id) {
                // params: slot1=b, slot2=x, slot3=g
                const b_abs = new_bp + 1;
                const bv = if (b_abs < MAX_STACK and b_abs < sp) stack[b_abs] else Value.UNDEFINED;
                if (bv.tag == .number and bv.data.number == 363 and dbg_wu363_n < 64) {
                    const g_abs = new_bp + 3;
                    const gv = if (g_abs < MAX_STACK and g_abs < sp) stack[g_abs] else Value.UNDEFINED;
                    const j = dbg_wu363_n;
                    dbg_wu363_gtag[j] = @intFromEnum(gv.tag);
                    if (gv.tag == .array or gv.tag == .object) {
                        const gi = gv.data.obj_idx;
                        const e0 = objects.getArrayElement(gi, 0);
                        const e1 = objects.getArrayElement(gi, 1);
                        const e2 = objects.getArrayElement(gi, 2);
                        dbg_wu363_e0[j] = if (e0.tag == .number) e0.data.number else -987654.0;
                        dbg_wu363_e1[j] = if (e1.tag == .number) e1.data.number else -987654.0;
                        dbg_wu363_e2[j] = if (e2.tag == .number) e2.data.number else -987654.0;
                    } else if (gv.tag == .number) {
                        dbg_wu363_e0[j] = gv.data.number; // the number value written
                    }
                    dbg_wu363_caller[j] = if (frame_count >= 2) frames[frame_count - 2].func_id else 0xFFFF;
                    dbg_wu363_n += 1;
                }
            }
            // ── mS keystream input capture at the target block.
            if (obj.func_id == dbg_ms_id and !dbg_ms_done) {
                // params: slot1=b, slot2=x(B/key), slot3=g(O/block), slot4=Y, slot5=L(array)
                const g_abs = new_bp + 3;
                const gv = if (g_abs < MAX_STACK and g_abs < sp) stack[g_abs] else Value.UNDEFINED;
                if (gv.tag == .number and gv.data.number == dbg_ms_target_block) {
                    dbg_ms_done = true;
                    dbg_ms_g = gv.data.number;
                    const x_abs = new_bp + 2;
                    const xv = if (x_abs < MAX_STACK) stack[x_abs] else Value.UNDEFINED;
                    dbg_ms_x = if (xv.tag == .number) xv.data.number else -1;
                    const L_abs = new_bp + 5;
                    const Lv = if (L_abs < MAX_STACK) stack[L_abs] else Value.UNDEFINED;
                    dbg_ms_L_tag = @intFromEnum(Lv.tag);
                    if (Lv.tag == .array or Lv.tag == .object) {
                        const li = Lv.data.obj_idx;
                        const e2 = objects.getArrayElement(li, 2);
                        const e3 = objects.getArrayElement(li, 3);
                        dbg_ms_L2 = if (e2.tag == .number) e2.data.number else -987654.0;
                        dbg_ms_L3 = if (e3.tag == .number) e3.data.number else -987654.0;
                    }
                }
            }
            // ── Decoder-construction entry trace.
            if (obj.func_id == dbg_dec_ch_id) {
                dbg_dec_ch_entries += 1;
            } else if (obj.func_id == dbg_dec_m6_id) {
                dbg_dec_m6_entries += 1;
                if (dbg_dec_m6_w_tag == 255) {
                    // M6 params: b,x,g,Y,L,F,W,... → W is the 7th param = slot 7.
                    const w_abs = new_bp + 7;
                    const wv = if (w_abs < MAX_STACK and w_abs < sp) stack[w_abs] else Value.UNDEFINED;
                    dbg_dec_m6_w_tag = @intFromEnum(wv.tag);
                    dbg_dec_m6_w_obj = if (wv.tag == .object or wv.tag == .array or wv.tag == .function) wv.data.obj_idx else 0xFFFFFFFF;
                }
            } else if (obj.func_id == dbg_dec_hh_id) {
                dbg_dec_hh_entries += 1;
                if (dbg_dec_hh_g_tag == 255) {
                    // Hh params: b,x,g,... → g is the 3rd param = slot 3.
                    const g_abs = new_bp + 3;
                    const gv = if (g_abs < MAX_STACK and g_abs < sp) stack[g_abs] else Value.UNDEFINED;
                    dbg_dec_hh_g_tag = @intFromEnum(gv.tag);
                    dbg_dec_hh_g_obj = if (gv.tag == .object or gv.tag == .array or gv.tag == .function) gv.data.obj_idx else 0xFFFFFFFF;
                }
            }
            return;
        }
    }

    // Not callable — discard args, push undefined. (JS would throw TypeError here;
    // we currently return undefined. Throwing is gated behind dbg_throw_not_callable
    // until the remaining non-callable divergences are eliminated.)
    dbg_notcallable += 1;
    recordNotCallable(last_lookup_name);
    sp -= argc;
    if (sp > 0) sp -= 1;
    // JS: calling a non-function throws "<name> is not a function". Enabled now
    // that eval lexical scope is correct (see callMethod for rationale).
    throwNotAFunction(last_lookup_name);
    _ = &dbg_throw_not_callable;
}

// Scratch buffer to hold eval/Function source while it is (re)compiled.
// eval sources for BotGuard's unpack step are large; give generous headroom.
var eval_src_buf: [512 * 1024]u8 = undefined;
pub var dbg_short_eval_buf: [262144]u8 = undefined;
pub var dbg_short_eval_len: usize = 0;
// Set by the .call_direct_eval opcode: the current call is a DIRECT eval, so
// the eval'd source must inherit the caller frame's lexical scope.
var eval_is_direct: bool = false;

/// Handle the eval / Function VM intrinsics.
///
/// eval(str): compile `str` as top-level code, append its bytecode, push a
/// frame at it so the main run loop executes it and its `ret` yields the value.
///
/// Function(...args, body): build a function `(function(a,b){ body })`, compile
/// it, and leave the resulting closure value on the stack.
fn evalIntrinsic(func_id: u16, argc: u8) void {
    dbg_eval_calls += 1;
    const direct_eval = func_id == builtins.N_EVAL and eval_is_direct;
    // The intrinsic arguments occupy stack[sp-argc .. sp]; the callee slot is
    // at stack[sp-argc-1]. eval uses its first argument; Function uses its
    // final argument as the body and preceding arguments as parameter lists.
    if (argc == 0 and func_id != builtins.N_FUNCTION) {
        sp -= 1; // pop callee
        push(Value.UNDEFINED);
        return;
    }

    // Function converts parameter fragments and the body to strings in
    // argument order. These references remain in fixed storage while the
    // wrapper is assembled and compiled.
    var function_args: [256]Value = undefined;
    if (func_id == builtins.N_FUNCTION) {
        var ai: u8 = 0;
        while (ai < argc) : (ai += 1) {
            function_args[ai] = Value.string(valueToStringIdx(stack[sp - argc + ai]));
            if (had_error) return;
        }
    }
    const src_val = if (func_id == builtins.N_FUNCTION)
        (if (argc == 0) Value.string(values.internString("")) else function_args[argc - 1])
    else stack[sp - argc];

    // Non-string eval arg returns the value unchanged (per spec eval returns
    // its argument when it is not a string).
    if (src_val.tag != .string) {
        const result = src_val;
        sp -= (argc + 1);
        push(result);
        return;
    }

    const src = values.getString(src_val.data.str_idx);
    if (src.len < 500 and dbg_short_eval_len + src.len + 1 <= dbg_short_eval_buf.len) {
        @memcpy(dbg_short_eval_buf[dbg_short_eval_len..][0..src.len], src); dbg_short_eval_len += src.len;
        dbg_short_eval_buf[dbg_short_eval_len] = '\n'; dbg_short_eval_len += 1;
    }

    // Trace: record every eval source's length (and a short prefix hash) so the
    // eval-source stream can be diffed vs the oracle to find the first eval whose
    // decoded source differs (the "mS=" truncation / varint-framing break point).
    if (dbg_evsrc_on and dbg_evsrc_n < dbg_evsrc_len_arr.len) {
        dbg_evsrc_len_arr[dbg_evsrc_n] = @intCast(src.len);
        var h: u32 = 2166136261;
        for (src) |c| { h = (h ^ c) *% 16777619; }
        dbg_evsrc_hash_arr[dbg_evsrc_n] = h;
        // Capture the FULL source text at the target eval index (for diffing the
        // truncated source).
        if (dbg_evsrc_n == dbg_evsrc_cap_idx) {
            const k = @min(src.len, dbg_evsrc_cap_buf.len);
            @memcpy(dbg_evsrc_cap_buf[0..k], src[0..k]);
            dbg_evsrc_cap_len = k;
        }
        dbg_evsrc_n += 1;
    }

    // Build the actual source to compile into our scratch buffer.
    var slen: usize = 0;
    if (func_id == builtins.N_FUNCTION) {
        // Function(...parameters, body): evaluating the wrapper yields the
        // generated function, with its declared parameters and global scope.
        slen = wrapFunctionSource(function_args[0..argc], src);
        if (slen == 0) { fail("Function: source too large"); return; }
    } else {
        // eval(src): compile the source verbatim.
        if (src.len > eval_src_buf.len) { fail("eval: source too large"); return; }
        @memcpy(eval_src_buf[0..src.len], src);
        slen = src.len;
    }

    // Pop args + callee now; the eval frame produces the result.
    sp -= (argc + 1);

    // Reset the completion register so a body with no expression statement
    // (or a nested eval) yields undefined rather than a stale value.
    completion = Value.UNDEFINED;

    // DEBUG: record the length + first bytes of each eval source.
    dbg_last_eval_len = slen;
    // DEBUG: capture the LARGEST eval source (the interpreter payload) and count
    // whether it contains a 'w=function' declaration, so we can see if `w` is a
    // module var (local) or an implicit global in the eval'd interpreter.
    if (slen > dbg_bigeval_len) {
        dbg_bigeval_len = slen;
        dbg_bigeval_is_now = true;
        // Isolate the BIG eval's hoisting: reset the w-hoist counter so we can
        // tell whether the interpreter IIFE declares `w` as a local.
        compiler.dbg_hoist_saw_w = 0;
        compiler.dbg_wdecl_count = 0;
        const k = @min(slen, dbg_bigeval_head.len);
        @memcpy(dbg_bigeval_head[0..k], eval_src_buf[0..k]);
        dbg_bigeval_head_len = k;
        // Persist a larger window of the big-eval source so we can map a
        // function's src_start / a srcPos back to the exact expression even
        // after later (per-instruction) evals clobber eval_src_buf.
        const fk = @min(slen, dbg_bigeval_full.len);
        @memcpy(dbg_bigeval_full[0..fk], eval_src_buf[0..fk]);
        dbg_bigeval_full_len = fk;
    }
    // Capture any eval source (of any size) that contains a `.String` member
    // access, so we can find the mis-compiled property read. Snapshot the first
    // such source we see.
    if (!dbg_dotstring_captured) {
        var di: usize = 0;
        while (di + 7 <= slen) : (di += 1) {
            if (eval_src_buf[di] == '.' and eval_src_buf[di+1] == 'S' and eval_src_buf[di+2] == 't' and
                eval_src_buf[di+3] == 'r' and eval_src_buf[di+4] == 'i' and eval_src_buf[di+5] == 'n' and eval_src_buf[di+6] == 'g') {
                dbg_dotstring_captured = true;
                const dk = @min(slen, dbg_dotstring_src.len);
                @memcpy(dbg_dotstring_src[0..dk], eval_src_buf[0..dk]);
                dbg_dotstring_src_len = dk;
                break;
            }
        }
        // Count 'w=' occurrences (declarators) and whether preceded by 'var '.
        dbg_bigeval_has_var = false;
        dbg_bigeval_weq = 0;
        var qi: usize = 0;
        while (qi + 1 < slen) : (qi += 1) {
            if (eval_src_buf[qi] == 'w' and eval_src_buf[qi + 1] == '=') dbg_bigeval_weq += 1;
        }
        // crude: does the payload start (after comment) with '(function('?
    }

    // Re-lex + re-parse + append-compile. This clobbers the transient
    // lexer/parser pools, which is safe: the original program is already
    // compiled to persistent bytecode/constants/functions.
    const n_tokens = lexer.tokenize(eval_src_buf[0..slen]);
    dbg_eval_tokens = @intCast(n_tokens);
    if (n_tokens == 0) { push(Value.UNDEFINED); return; }

    const root = parser.parse(n_tokens);
    dbg_eval_tokpos = @intCast(parser.tokenPos());
    dbg_eval_stoptok = parser.currentTokenType();
    dbg_eval_stopbyte = parser.currentTokenStart();
    if (dbg_bigeval_is_now) {
        dbg_bigeval_is_now = false;
        dbg_bigeval_tokens = @intCast(n_tokens);
        dbg_bigeval_tokpos = @intCast(parser.tokenPos());
        dbg_bigeval_nodes = parser.nodeCount();
        dbg_bigeval_parse_err = parser.hasError();
        dbg_bigeval_root_null = (root == parser.NULL_NODE);
    }
    if (root == parser.NULL_NODE or parser.hasError()) {
        // JS-correct: a direct eval of INCOMPLETE source throws SyntaxError
        // "Unexpected end of input". BotGuard's anti-tamper deliberately evals
        // truncated snippets to generate this error (encoded into the transcript
        // via uI); silently returning undefined desynced the error budget and the
        // register decode. Only the bare-identifier direct-eval form reaches here.
        if (parser.errorWasUnexpectedEof()) {
            // Capture the FIRST truncated-eval source that triggers the EOI throw,
            // so we can compare against jsdom (which collects 0 of these).
            if (!dbg_eoi_captured) {
                dbg_eoi_captured = true;
                const ek = @min(slen, dbg_eoi_src.len);
                @memcpy(dbg_eoi_src[0..ek], eval_src_buf[0..ek]);
                dbg_eoi_src_len = ek;
                dbg_eoi_slen = slen;
                dbg_eoi_stopbyte = parser.currentTokenStart();
                dbg_eoi_stoptok = parser.currentTokenType();
                // Capture the frame stack at the EOI eval so we can find what
                // built the truncated eval argument.
                dbg_eoi_framen = @min(frame_count, dbg_eoi_func.len);
                var efi: usize = 0;
                while (efi < dbg_eoi_framen) : (efi += 1) {
                    const ef = frames[frame_count - 1 - efi];
                    dbg_eoi_func[efi] = ef.func_id;
                    dbg_eoi_ip[efi] = ef.ip;
                }
                // Capture func 149 (the arg builder, frame[1])'s local slot tags +
                // numbers, so we can see what fed the truncated eval arg.
                if (frame_count >= 2) {
                    const bldr = frames[frame_count - 2];
                    var bli: usize = 0;
                    while (bli < 12 and bldr.bp + bli < MAX_STACK) : (bli += 1) {
                        const sv = stack[bldr.bp + bli];
                        dbg_eoi_bldr_tag[bli] = @intFromEnum(sv.tag);
                        dbg_eoi_bldr_num[bli] = if (sv.tag == .number) sv.data.number else -999999;
                        dbg_eoi_bldr_slen[bli] = if (sv.tag == .string) @intCast(values.getString(sv.data.str_idx).len) else 0;
                    }
                }
            }
            const serr = makeErrorObject("SyntaxError", "Unexpected end of input");
            had_error = true;
            // throwException unwinds to the nearest try/catch (clearing had_error
            // and repositioning the frame/ip). It does NOT push a value, so we
            // must not push here either.
            throwException(serr);
            return;
        }
        // Every syntax error aborts the entire eval before it can mutate any
        // binding. In particular x=' is a lexical error, not an assignment.
        throwException(makeErrorObject("SyntaxError", if (lexer.hasError()) "Invalid or unexpected token" else "Unexpected token"));
        return;
    }

    dbg_eval_parse_err = parser.hasError();
    dbg_eval_nodes = parser.nodeCount();
    // Capture the eval-CALLER frame (the frame that invoked eval) so the compiler
    // can resolve the eval body's free identifiers against the caller's lexical
    // scope, and the VM can bind the resulting caller-scope upvalues to this live
    // frame by reference. This is the JS-correct direct-eval scope, replacing the
    // lossy publish-to-global approximation (exposeAllLiveScopes).
    const eval_caller_func: u16 = if (direct_eval and frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
    const eval_caller_bp: u16 = if (frame_count > 0) frames[frame_count - 1].bp else 0;
    const eval_receiver = if (direct_eval and frame_count > 0) stack[eval_caller_bp] else Value.object(global_obj);
    const eval_caller_closure: u32 = if (frame_count > 0) frames[frame_count - 1].closure_obj else objects.NULL_OBJ;
    const dbg_fn_before = compiler.dbgFunctionCount();
    const code_start = compiler.compileEvalAt(root, eval_caller_func, if (direct_eval and frame_count > 0) frames[frame_count - 1].ip else 0);
    dbg_eval_compile_err = compiler.hasError();
    if (code_start == 0 or compiler.hasError()) { push(Value.UNDEFINED); return; }
    dbg_eval_compiled += 1;
    const eval_body_func: u16 = compiler.lastEvalBodyFunc();
    // If this eval's BODY is the target debug function, snapshot its source +
    // the eval-caller func_id (so we can inspect where free var `bY` should bind).
    if (!dbg_targetfn_captured and (eval_body_func == dbg_targetfn_want or
        (dbg_targetfn_want >= dbg_fn_before and dbg_targetfn_want < compiler.dbgFunctionCount()))) {
        dbg_targetfn_captured = true;
        const tk = @min(slen, dbg_targetfn_src.len);
        @memcpy(dbg_targetfn_src[0..tk], eval_src_buf[0..tk]);
        dbg_targetfn_src_len = tk;
        dbg_targetfn_fn_before = dbg_fn_before;
        dbg_targetfn_fn_after = compiler.dbgFunctionCount();
        dbg_targetfn_evalcaller = eval_caller_func;
        dbg_targetfn_evalbody = eval_body_func;
        // Capture upval0's descriptor (kind + index) for the target eval body.
        if (eval_body_func != 0xFFFF and compiler.upvalCount(eval_body_func) > 0) {
            const d0 = compiler.upvalDescAt(eval_body_func, 0);
            dbg_targetfn_uv0_kind = d0.eval_kind;
            dbg_targetfn_uv0_index = d0.index;
            dbg_targetfn_uv0_count = compiler.upvalCount(eval_body_func);
            // For a CALLER_UPVAL, inspect the eval-caller's matched upvalue:
            // name, is_local, eval_kind, and its runtime value tag (via closure).
            if (d0.eval_kind == compiler.EVAL_UV_CALLER_UPVAL and eval_caller_func != 0xFFFF) {
                dbg_targetfn_caller_uvname = compiler.funcUpvalName(eval_caller_func, d0.index);
                const cd = compiler.upvalDescAt(eval_caller_func, d0.index);
                dbg_targetfn_caller_uv_islocal = if (cd.is_local) 1 else 0;
                dbg_targetfn_caller_uv_kind = cd.eval_kind;
                dbg_targetfn_caller_uv_index = cd.index;
                dbg_targetfn_caller_upcount = compiler.upvalCount(eval_caller_func);
                // Runtime value of the caller's closure upvalue d0.index.
                if (eval_caller_closure != objects.NULL_OBJ) {
                    var cv = Value.UNDEFINED;
                    if (objects.isClosureUpvalClosed(eval_caller_closure, d0.index)) {
                        cv = objects.getClosureUpvalClosedVal(eval_caller_closure, d0.index);
                        dbg_targetfn_caller_uv_closed = 1;
                    } else {
                        const a = objects.getClosureUpvalAddr(eval_caller_closure, d0.index);
                        if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) cv = stack[a];
                    }
                    dbg_targetfn_caller_uv_valtag = @intFromEnum(cv.tag);
                }
                // Does `bY` also exist as a GLOBAL right now?
                dbg_targetfn_global_has = if (objects.hasOwnProperty(global_obj, values.internString("bY"))) 1 else 0;
                dbg_targetfn_global_tag = @intFromEnum(objects.getProperty(global_obj, values.internString("bY")).tag);
            }
        }
    }

    if (func_id == builtins.N_FUNCTION) {
        // The wrapped source is `(function(){...})` whose evaluation leaves the
        // function value on the stack. Running the eval frame yields it.
    }

    // Push a frame to execute the eval'd code. bp points at current sp; the
    // compiled eval reserves local slot 0 (this) via its leading load_undef.
    if (frame_count >= MAX_FRAMES) { fail("eval: frame overflow"); push(Value.UNDEFINED); return; }
    const new_bp = sp;
    checkFrameOverlap(@intCast(new_bp), 0xFFFE);

    // Build the eval frame's CLOSURE so free identifiers in the eval body (and
    // functions it defines) resolve to the eval-caller's lexical scope BY
    // REFERENCE — JS-correct direct-eval scope. Each caller-scope upvalue:
    //   EVAL_UV_CALLER_LOCAL: bind to the live caller frame slot (caller_bp+index).
    //   EVAL_UV_CALLER_UPVAL: share/close the caller closure's upvalue at index.
    var eval_closure: u32 = objects.NULL_OBJ;
    if (eval_body_func != 0xFFFF) {
        const n_uv = compiler.upvalCount(eval_body_func);
        if (n_uv > 0) {
            eval_closure = objects.createClosure(eval_body_func, n_uv);
            var ui: u16 = 0;
            while (ui < n_uv) : (ui += 1) {
                const d = compiler.upvalDescAt(eval_body_func, ui);
                if (d.eval_kind == compiler.EVAL_UV_CALLER_LOCAL) {
                    // Caller frame local slot -> live stack address (by reference).
                    objects.setClosureUpvalAddr(eval_closure, ui, @as(u32, eval_caller_bp) + d.index);
                } else if (d.eval_kind == compiler.EVAL_UV_CALLER_UPVAL) {
                    // Share the caller's binding regardless of whether its
                    // defining frame is still live.
                    if (eval_caller_closure != objects.NULL_OBJ) {
                        const pidx: u16 = d.index;
                        objects.shareClosureUpvalCell(eval_closure, ui, eval_caller_closure, pidx);
                    }
                }
            }
        }
    }

    ctor_is[frame_count] = false;
    frames[frame_count] = .{
        // Keep the eval body's descriptor so nested direct eval resolves its
        // caller's local names and captured bindings like any other frame.
        .func_id = eval_body_func,
        .ip = code_start,
        .bp = @intCast(new_bp),
        .closure_obj = eval_closure,
    };
    frame_count += 1;
    // Reserve local slot 0 for `this`.
    push(eval_receiver);
    if (eval_body_func != 0xFFFF) {
        const elc = compiler.getFunction(eval_body_func).local_count;
        var ei: u16 = 1;
        while (ei < elc) : (ei += 1) push(Value.UNDEFINED);
    }
}

/// Expose the named locals of ALL currently-live frames as globals so DIRECT
/// eval'd code (and functions it builds that run later) can resolve free
/// identifiers from any enclosing scope. BotGuard's whole program runs nested
/// inside one interpreter IIFE `(function(){var ...w...}).call(this)`, and its
/// per-instruction handlers are built via `function(T){return eval(T)}(snippet)`
/// where the snippet reads interpreter helpers (`w`, `n`, ...) that live in the
/// IIFE frame. Since JS direct eval inherits the caller's full lexical chain and
/// that chain is exactly the live frame stack here, publishing every live
/// frame's named locals reproduces the visibility. We do NOT overwrite an
/// existing own global with a DIFFERENT non-undefined value (so real
/// globals/builtins win), and skip undefined values.
pub var dbg_expose_frames: u32 = 0;
pub var dbg_expose_published: u32 = 0;
pub var dbg_expose_saw_w: u32 = 0;
pub var dbg_ret_published: u32 = 0;
pub var dbg_ret_saw_w: u32 = 0;
/// Publish a returning frame's function-valued named locals as globals (see the
/// call site for rationale). Function values only; never clobbers a non-function
/// existing global.
fn exposeReturningFrameHelpers(fr: CallFrame) void {
    if (fr.func_id == 0xFFFF or fr.func_id == 0xFFFE or fr.func_id >= 0xF000) return;
    const cnt = compiler.funcNameTabCount(fr.func_id);
    if (cnt == 0) return;
    var i: u16 = 0;
    while (i < cnt) : (i += 1) {
        const nm = compiler.funcLocalName(fr.func_id, i);
        if (nm == 0xFFFFFFFF) continue;
        const addr: u32 = @as(u32, fr.bp) + i;
        if (addr >= MAX_STACK or addr >= sp) continue;
        const v = stack[addr];
        // Publish helper FUNCTIONS and OBJECT/ARRAY references (by reference, so
        // assignments through the eval'd handler hit the same object — needed
        // for `webPoSignalOutput[0]=getMinter`). Skip primitives/undefined.
        if (v.tag != .function and v.tag != .object and v.tag != .array) continue;
        const nmstr = values.getString(nm);
        if (nmstr.len == 1 and nmstr[0] == 'w') dbg_ret_saw_w += 1;
        const existing = objects.getProperty(global_obj, nm);
        if (!objects.hasOwnProperty(global_obj, nm) or (existing.tag != .function and existing.tag != .object and existing.tag != .array)) {
            objects.setProperty(global_obj, nm, v);
            dbg_ret_published += 1;
        }
    }
}
fn exposeAllLiveScopes() void {
    dbg_expose_frames = @intCast(frame_count);
    // JS direct eval resolves a free identifier to the NEAREST enclosing lexical
    // binding. The live frame stack is that chain: frames[0]=outermost,
    // frames[frame_count-1]=innermost (the direct-eval caller). To make the
    // nearest binding win, publish OUTER frames first and INNER frames last so
    // an inner scope's binding overwrites an outer one of the same name.
    //
    // NOTE (bug fix): the old code walked inner->outer AND allowed any
    // function-valued local to clobber an already-published binding (via
    // `or v.tag == .function`). That let an OUTER frame's function-valued `K`
    // overwrite the INNER frame's bank-valued `K`, so a synthesized opcode
    // handler read `K` as a function instead of the register bank (op#134
    // divergence). Correct precedence is nearest-scope-wins, regardless of type.
    var fi: usize = 0;
    while (fi < frame_count) : (fi += 1) {
        const fr = frames[fi];
        if (fr.func_id == 0xFFFF or fr.func_id == 0xFFFE or fr.func_id >= 0xF000) continue;
        const cnt = compiler.funcNameTabCount(fr.func_id);
        var i: u16 = 0;
        while (i < cnt) : (i += 1) {
            const nm = compiler.funcLocalName(fr.func_id, i);
            if (nm == 0xFFFFFFFF) continue;
            const addr: u32 = @as(u32, fr.bp) + i;
            if (addr >= MAX_STACK) continue;
            const v = stack[addr];
            if (v.tag == .undefined) continue;
            const nmstr = values.getString(nm);
            if (nmstr.len == 1 and nmstr[0] == 'w') dbg_expose_saw_w += 1;
            // NEVER clobber the VM intrinsics `eval`/`Function`: a frame may have
            // a local named `eval` (e.g. `var eval="..."`), which in JS only
            // shadows within that scope — publishing it as a global would break
            // the native eval for ALL subsequent direct evals (they'd call a
            // string and get undefined). Keep the native builtin intact.
            if (eql(nmstr, "eval") or eql(nmstr, "Function")) {
                const cur = objects.getProperty(global_obj, nm);
                if (cur.tag == .function and builtins.isVmIntrinsic(dbgFuncIdOf(cur))) continue;
            }
            // Publish this frame's binding. Because we go outer->inner, a nearer
            // (inner) scope's value is applied later and wins — matching JS
            // direct-eval lexical resolution.
            objects.setProperty(global_obj, nm, v);
            dbg_expose_published += 1;
        }
    }
}

/// Wrap Function parameter fragments and its body in eval_src_buf.
/// Returns the wrapped length.
fn wrapFunctionSource(args: []const Value, body: []const u8) usize {
    const prefix = "(function(";
    const body_start = "){";
    const suffix = "})";
    var total: usize = prefix.len + body_start.len + body.len + suffix.len;
    const param_count = if (args.len == 0) 0 else args.len - 1;
    for (args[0..param_count], 0..) |arg, i| {
        total += values.getString(arg.data.str_idx).len;
        if (i != 0) total += 1;
    }
    if (total > eval_src_buf.len) return 0;
    var o: usize = 0;
    @memcpy(eval_src_buf[o .. o + prefix.len], prefix);
    o += prefix.len;
    for (args[0..param_count], 0..) |arg, i| {
        if (i != 0) { eval_src_buf[o] = ','; o += 1; }
        const param = values.getString(arg.data.str_idx);
        @memcpy(eval_src_buf[o .. o + param.len], param);
        o += param.len;
    }
    @memcpy(eval_src_buf[o .. o + body_start.len], body_start);
    o += body_start.len;
    @memcpy(eval_src_buf[o .. o + body.len], body);
    o += body.len;
    @memcpy(eval_src_buf[o .. o + suffix.len], suffix);
    o += suffix.len;
    return o;
}

/// Method call: stack is [func][receiver][arg0..arg(argc-1)].
/// Invokes func with this=receiver. Natives receive [receiver, ...args] so the
/// receiver is args[0] (matching Array/String.prototype native signatures).
// ── Reg-writer func (e.g. func 25) entry capture for reg-363 (x==363): seed g + caller.
pub var dbg_rw_id: u16 = 0xFFFF;
pub var dbg_rw_n: u32 = 0;
pub var dbg_rw_gtag: [32]u8 = [_]u8{255} ** 32;
pub var dbg_rw_gobj: [32]u32 = [_]u32{0xFFFFFFFF} ** 32;
pub var dbg_rw_e0: [32]f64 = [_]f64{-987654.0} ** 32;
pub var dbg_rw_e1: [32]f64 = [_]f64{-987654.0} ** 32;
pub var dbg_rw_e2: [32]f64 = [_]f64{-987654.0} ** 32;
pub var dbg_rw_caller: [32]u16 = [_]u16{0xFFFF} ** 32;
pub var dbg_rw_caller_ip: [32]u32 = [_]u32{0} ** 32;
pub var dbg_rw_callerA: [32]f64 = [_]f64{-987654.0} ** 32;
pub var dbg_rw_callerV_tag: [32]u8 = [_]u8{255} ** 32;
pub var dbg_rw_callerV_obj: [32]u32 = [_]u32{0xFFFFFFFF} ** 32;
pub fn dbgRwCallerA(i: usize) f64 { return if (i < 32) dbg_rw_callerA[i] else -987654.0; }
pub fn dbgRwCallerVTag(i: usize) u8 { return if (i < 32) dbg_rw_callerV_tag[i] else 255; }
pub fn dbgRwCallerVObj(i: usize) u32 { return if (i < 32) dbg_rw_callerV_obj[i] else 0xFFFFFFFF; }
pub var dbg_rw_regidx: f64 = 363; // which register index to capture (default 363)
pub fn dbgRwSetId(id: u16) void { dbg_rw_id = id; }
pub fn dbgRwSetRegIdx(r: f64) void { dbg_rw_regidx = r; }
pub fn dbgRwN() u32 { return dbg_rw_n; }
pub fn dbgRwGTag(i: usize) u8 { return if (i < 32) dbg_rw_gtag[i] else 255; }
pub fn dbgRwGObj(i: usize) u32 { return if (i < 32) dbg_rw_gobj[i] else 0xFFFFFFFF; }
pub fn dbgRwE0(i: usize) f64 { return if (i < 32) dbg_rw_e0[i] else -987654.0; }
pub fn dbgRwE1(i: usize) f64 { return if (i < 32) dbg_rw_e1[i] else -987654.0; }
pub fn dbgRwE2(i: usize) f64 { return if (i < 32) dbg_rw_e2[i] else -987654.0; }
pub fn dbgRwCaller(i: usize) u16 { return if (i < 32) dbg_rw_caller[i] else 0xFFFF; }
pub fn dbgRwCallerIp(i: usize) u32 { return if (i < 32) dbg_rw_caller_ip[i] else 0; }
// ── Cell-ctor l(b,x,g,Y,L,F) seed-arg capture for reg-363 (F==363).
// Generic object-array element inspector (debug).
pub fn dbgObjArrLen(obj_idx: u32) u32 { return objects.arrayLength(obj_idx); }
pub fn dbgObjArrElem(obj_idx: u32, i: u32) f64 {
    const e = objects.getArrayElement(obj_idx, i);
    return if (e.tag == .number) e.data.number else -987654.0;
}
pub fn dbgObjArrElemTag(obj_idx: u32, i: u32) u8 {
    return @intFromEnum(objects.getArrayElement(obj_idx, i).tag);
}
pub var dbg_lc_id: u16 = 0xFFFF;
pub var dbg_lc_regidx: f64 = 363;
pub fn dbgLcSetRegIdx(r: f64) void { dbg_lc_regidx = r; }
pub var dbg_lc_n: u32 = 0;
pub var dbg_lc_gtag: [64]u8 = [_]u8{255} ** 64;
pub var dbg_lc_gnum: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_lc_gobj: [64]u32 = [_]u32{0xFFFFFFFF} ** 64;
pub var dbg_lc_caller: [64]u16 = [_]u16{0xFFFF} ** 64;
pub fn dbgLcSetId(id: u16) void { dbg_lc_id = id; }
pub fn dbgLcN() u32 { return dbg_lc_n; }
pub fn dbgLcGTag(i: usize) u8 { return if (i < 64) dbg_lc_gtag[i] else 255; }
pub fn dbgLcGNum(i: usize) f64 { return if (i < 64) dbg_lc_gnum[i] else -987654.0; }
pub fn dbgLcGObj(i: usize) u32 { return if (i < 64) dbg_lc_gobj[i] else 0xFFFFFFFF; }
pub fn dbgLcCaller(i: usize) u16 { return if (i < 64) dbg_lc_caller[i] else 0xFFFF; }
// ── Q(363) cell-identity trace: obj of x.Y[363] at each Q(363) entry.
pub var dbg_q363cell: [1024]u32 = [_]u32{0xFFFFFFFF} ** 1024;
pub var dbg_q363cell_n: usize = 0;
pub fn dbgQ363CellN() usize { return dbg_q363cell_n; }
pub fn dbgQ363Cell(i: usize) u32 { return if (i < 1024) dbg_q363cell[i] else 0xFFFFFFFF; }
// ── set_elem watch on a specific object (reg-363 cell): capture index-0 writes
// (the seed element) with value + caller, to find who sets the wrong seed.
pub var dbg_selem_watch_obj: u32 = 0xFFFFFFFF;
pub var dbg_selem_n: u32 = 0;
pub var dbg_selem_idx: [96]u32 = [_]u32{0xFFFFFFFF} ** 96;
pub var dbg_selem_val: [96]f64 = [_]f64{-987654.0} ** 96;
pub var dbg_selem_caller: [96]u16 = [_]u16{0xFFFF} ** 96;
pub var dbg_selem_ip: [96]u32 = [_]u32{0} ** 96;
pub fn dbgSelemWatchSet(obj: u32) void { dbg_selem_watch_obj = obj; dbg_selem_n = 0; }
pub fn dbgSelemN() u32 { return dbg_selem_n; }
pub fn dbgSelemIdx(i: usize) u32 { return if (i < 96) dbg_selem_idx[i] else 0xFFFFFFFF; }
pub fn dbgSelemVal(i: usize) f64 { return if (i < 96) dbg_selem_val[i] else -987654.0; }
pub fn dbgSelemCaller(i: usize) u16 { return if (i < 96) dbg_selem_caller[i] else 0xFFFF; }
pub fn dbgSelemIp(i: usize) u32 { return if (i < 96) dbg_selem_ip[i] else 0; }
// ── make_array watch: capture the array build whose first elem == a target.
pub var dbg_mkarr_watch_e0: i64 = 0;
pub var dbg_mkarr_done: bool = false;
pub var dbg_mkarr_obj: u32 = 0xFFFFFFFF;
pub var dbg_mkarr_count: u16 = 0;
pub var dbg_mkarr_func: u16 = 0xFFFF;
pub var dbg_mkarr_ip: u32 = 0;
pub var dbg_mkarr_elems: [4]f64 = [_]f64{-987654.0} ** 4;
pub fn dbgMkArrWatchSet(e0: i64) void { dbg_mkarr_watch_e0 = e0; dbg_mkarr_done = false; }
pub fn dbgMkArrObj() u32 { return dbg_mkarr_obj; }
pub fn dbgMkArrCount() u16 { return dbg_mkarr_count; }
pub fn dbgMkArrFunc() u16 { return dbg_mkarr_func; }
pub fn dbgMkArrIp() u32 { return dbg_mkarr_ip; }
pub fn dbgMkArrElem(i: usize) f64 { return if (i < 4) dbg_mkarr_elems[i] else -987654.0; }
// ── Register-363 cell `.concat` closure UPVALUE snapshot (for standalone replay).
pub var dbg_cc_id: u16 = 0xFFFF;
pub var dbg_cc_target_call: u32 = 0;
pub var dbg_cc_calls: u32 = 0;
pub var dbg_cc_done: bool = false;
pub var dbg_cc_uvcount: u16 = 0;
pub var dbg_cc_recv: u32 = 0xFFFFFFFF;
pub var dbg_cc_uv_tag: [16]u8 = [_]u8{255} ** 16;
pub var dbg_cc_uv_num: [16]f64 = [_]f64{-987654.0} ** 16;
pub var dbg_cc_uv_obj: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_cc_garr: [10]f64 = [_]f64{-987654.0} ** 10;
pub var dbg_cc_garr_tag: [10]u8 = [_]u8{255} ** 10;
pub var dbg_cc_garr_obj: [10]u32 = [_]u32{0xFFFFFFFF} ** 10;
pub var dbg_cc_garr_uv: u16 = 0xFFFF;
pub var dbg_cc_garr_len: u32 = 0;
pub fn dbgCcGarrTag(i: usize) u8 { return if (i < 10) dbg_cc_garr_tag[i] else 255; }
pub fn dbgCcGarrObj(i: usize) u32 { return if (i < 10) dbg_cc_garr_obj[i] else 0xFFFFFFFF; }
pub fn dbgCcGarrLen() u32 { return dbg_cc_garr_len; }
pub fn dbgCcSet(id: u16, target_call: u32) void { dbg_cc_id = id; dbg_cc_target_call = target_call; dbg_cc_calls = 0; dbg_cc_done = false; }
pub fn dbgCcCalls() u32 { return dbg_cc_calls; }
pub fn dbgCcDone() bool { return dbg_cc_done; }
pub fn dbgCcUvCount() u16 { return dbg_cc_uvcount; }
pub fn dbgCcRecv() u32 { return dbg_cc_recv; }
pub fn dbgCcUvTag(i: usize) u8 { return if (i < 16) dbg_cc_uv_tag[i] else 255; }
pub fn dbgCcUvNum(i: usize) f64 { return if (i < 16) dbg_cc_uv_num[i] else -987654.0; }
pub fn dbgCcUvObj(i: usize) u32 { return if (i < 16) dbg_cc_uv_obj[i] else 0xFFFFFFFF; }
pub fn dbgCcGarr(i: usize) f64 { return if (i < 10) dbg_cc_garr[i] else -987654.0; }
pub fn dbgCcGarrUv() u16 { return dbg_cc_garr_uv; }
// ── Register-cell `.concat(P)` setter watch (reg-363 seed writes).
pub var dbg_concat_watch_obj: u32 = 0xFFFFFFFF;
pub var dbg_concat_n: u32 = 0;
pub var dbg_concat_ptag: [64]u8 = [_]u8{255} ** 64;
pub var dbg_concat_pobj: [64]u32 = [_]u32{0xFFFFFFFF} ** 64;
pub var dbg_concat_e0: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_concat_e1: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_concat_e2: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_concat_caller: [64]u16 = [_]u16{0xFFFF} ** 64;
pub var dbg_concat_caller_ip: [64]u32 = [_]u32{0} ** 64;
pub fn dbgConcatWatchSet(obj: u32) void { dbg_concat_watch_obj = obj; dbg_concat_n = 0; }
pub fn dbgConcatN() u32 { return dbg_concat_n; }
pub fn dbgConcatPTag(i: usize) u8 { return if (i < 64) dbg_concat_ptag[i] else 255; }
pub fn dbgConcatE0(i: usize) f64 { return if (i < 64) dbg_concat_e0[i] else -987654.0; }
pub fn dbgConcatE1(i: usize) f64 { return if (i < 64) dbg_concat_e1[i] else -987654.0; }
pub fn dbgConcatE2(i: usize) f64 { return if (i < 64) dbg_concat_e2[i] else -987654.0; }
pub fn dbgConcatCaller(i: usize) u16 { return if (i < 64) dbg_concat_caller[i] else 0xFFFF; }
pub fn dbgConcatCallerIp(i: usize) u32 { return if (i < 64) dbg_concat_caller_ip[i] else 0; }
pub var dbg_concat_pnum: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_concat_firststr: [64]u8 = undefined;
pub var dbg_concat_firststr_len: usize = 0;
pub fn dbgConcatPNum(i: usize) f64 { return if (i < 64) dbg_concat_pnum[i] else -987654.0; }
pub fn dbgConcatFirstStr() []const u8 { return dbg_concat_firststr[0..dbg_concat_firststr_len]; }
pub fn dbgConcatWatchObj() u32 { return dbg_concat_watch_obj; }
fn callMethod(argc: u8) void {
    // func is below receiver+args (argc+2 slots from top).
    const need: u16 = @as(u16, argc) + 2;
    if (sp < need) { fail("method: stack underflow"); return; }
    const func_slot: u16 = sp - need;
    const recv_slot: u16 = func_slot + 1;
    const func_val = stack[func_slot];

    // ── Register-363 cell `.concat` (func dbg_cc_id) UPVALUE capture: at the
    // Nth invocation (dbg_cc_target_call), snapshot the closure's upvalue values
    // (r, D, F, Y, g[], W-result) so the formula can be replicated standalone.
    if (dbg_cc_id != 0xFFFF and func_val.tag == .function
        and objects.closureFuncId(func_val.data.func_idx) == dbg_cc_id) {
        const rvcc = stack[recv_slot];
        const rvcc_obj = if (rvcc.tag == .object or rvcc.tag == .array) rvcc.data.obj_idx else 0xFFFFFFFF;
        // Trigger on the FIRST concat call whose receiver is the target cell obj
        // (dbg_cc_target_call reused as the target cell obj_idx).
        if (rvcc_obj == dbg_cc_target_call and !dbg_cc_done) {
            dbg_cc_calls += 1;
            dbg_cc_done = true;
            const clo = func_val.data.func_idx;
            const uvc = objects.closureUpvalCount(clo);
            dbg_cc_uvcount = uvc;
            const rv = stack[recv_slot];
            dbg_cc_recv = if (rv.tag == .object or rv.tag == .array) rv.data.obj_idx else 0xFFFFFFFF;
            var ui: u16 = 0;
            while (ui < uvc and ui < 16) : (ui += 1) {
                var uv: Value = Value.UNDEFINED;
                if (objects.isClosureUpvalClosed(clo, ui)) uv = objects.getClosureUpvalClosedVal(clo, ui)
                else { const a = objects.getClosureUpvalAddr(clo, ui); if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) uv = stack[a]; }
                dbg_cc_uv_tag[ui] = @intFromEnum(uv.tag);
                dbg_cc_uv_num[ui] = if (uv.tag == .number) uv.data.number else -987654.0;
                dbg_cc_uv_obj[ui] = if (uv.tag == .object or uv.tag == .array or uv.tag == .function) uv.data.obj_idx else 0xFFFFFFFF;
                // If this upvalue is the g[] array, snapshot its first 10 elems.
                if ((uv.tag == .array or uv.tag == .object)) {
                    const gi = uv.data.obj_idx;
                    const gl = objects.arrayLength(gi);
                    if (gl >= 10) {
                        var ge: usize = 0;
                        while (ge < 10) : (ge += 1) {
                            const gev = objects.getArrayElement(gi, @intCast(ge));
                            dbg_cc_garr[ge] = if (gev.tag == .number) gev.data.number else -987654.0;
                            dbg_cc_garr_tag[ge] = @intFromEnum(gev.tag);
                            dbg_cc_garr_obj[ge] = if (gev.tag == .object or gev.tag == .array or gev.tag == .function) gev.data.obj_idx else 0xFFFFFFFF;
                        }
                        dbg_cc_garr_uv = ui;
                        dbg_cc_garr_len = gl;
                    }
                }
            }
        }
    }
    // ── (old concat-arg capture, kept but inert when dbg_concat_watch_obj unset)
    if (dbg_concat_watch_obj != 0xFFFFFFFF) {
        const rv = stack[recv_slot];
        if ((rv.tag == .object or rv.tag == .array) and rv.data.obj_idx == dbg_concat_watch_obj
            and eql(values.getString(last_lookup_name), "concat") and dbg_concat_n < 64) {
            const pv = if (argc >= 1) stack[recv_slot + 1] else Value.UNDEFINED;
            const j = dbg_concat_n;
            dbg_concat_ptag[j] = @intFromEnum(pv.tag);
            if (pv.tag == .array or pv.tag == .object) {
                const pi = pv.data.obj_idx;
                dbg_concat_pobj[j] = pi;
                const e0 = objects.getArrayElement(pi, 0);
                const e1 = objects.getArrayElement(pi, 1);
                const e2 = objects.getArrayElement(pi, 2);
                dbg_concat_e0[j] = if (e0.tag == .number) e0.data.number else -987654.0;
                dbg_concat_e1[j] = if (e1.tag == .number) e1.data.number else -987654.0;
                dbg_concat_e2[j] = if (e2.tag == .number) e2.data.number else -987654.0;
            }
            if (pv.tag == .string) {
                const ps = values.getString(pv.data.str_idx);
                dbg_concat_pnum[j] = -888888.0;
                if (j == 0) { const cn = @min(ps.len, dbg_concat_firststr.len); @memcpy(dbg_concat_firststr[0..cn], ps[0..cn]); dbg_concat_firststr_len = cn; }
            } else if (pv.tag == .number) dbg_concat_pnum[j] = pv.data.number;
            dbg_concat_caller[j] = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
            dbg_concat_caller_ip[j] = if (frame_count > 0) frames[frame_count - 1].ip else 0;
            dbg_concat_n += 1;
        }
    }

    if (func_val.tag == .function) {
        const obj_idx: u32 = func_val.data.func_idx;
        const obj = objects.getObject(obj_idx);
        if (obj.obj_type == .function) {
            // Intrinsics / fn-methods: fall back to plain-call semantics using
            // the region starting at the func slot (receiver is ignored by them).
            if (builtins.isVmIntrinsic(obj.func_id) or builtins.isFnMethod(obj.func_id)) {
                const receiver = stack[recv_slot];
                // Collapse [func][recv][args] -> [func][args] then dispatch.
                // Shift args down over the receiver slot.
                var k: u16 = recv_slot;
                while (k + 1 < sp) : (k += 1) stack[k] = stack[k + 1];
                sp -= 1;
                if (builtins.isVmIntrinsic(obj.func_id)) evalIntrinsic(obj.func_id, argc)
                else fnMethodCall(obj.func_id, obj_idx, argc, receiver);
                return;
            }

            // Array iteration methods invoke a JS callback per element and thus
            // need VM re-entrancy; handle them here rather than in callNative.
            if (isArrayIterMethod(obj.func_id)) {
                const recv = stack[recv_slot];
                const cb = if (argc >= 1) stack[recv_slot + 1] else Value.UNDEFINED;
                const arg2 = if (argc >= 2) stack[recv_slot + 2] else Value.UNDEFINED;
                const result = arrayIterMethod(obj.func_id, recv, cb, arg2);
                if (operation_aborted) return;
                sp = func_slot;
                push(result);
                return;
            }

            if (obj.func_id >= 0xF000) {
                dbg_native_calls += 1;
                if (dbg_callrec_on) dbgRecordNative(obj.func_id);
                // Coercion/global natives (String, Number, Object, Boolean,
                // parseInt/Float, isNaN, ...) IGNORE their `this`: JS
                // `global.String(x)` behaves like `String(x)`. Our method-call
                // path prepends the receiver as args[0], which made these
                // stringify/coerce the GLOBAL object instead of the real arg
                // (e.g. `L.String(65)` → "[object Object]" not "65"), cascading
                // into undefined-receiver throws. For these, drop the receiver.
                const nargs = if (builtins.nativeIgnoresReceiver(obj.func_id))
                    stack[recv_slot + 1 .. sp]
                else
                    stack[recv_slot .. sp];
                const nargc: u8 = @intCast(nargs.len);
                const result = builtins.callNative(obj.func_id, nargs, nargc);
                if (operation_aborted) return;
                sp = func_slot;
                if (checkNativeThrow()) return;
                push(result);
                return;
            }

            // User function: bp = receiver slot (this = receiver, args at 1..N).
            dbg_user_calls += 1;
            if (dbg_callrec_on and dbg_callrec_n < dbg_callrec_names.len) {
                dbg_callrec_names[dbg_callrec_n] = last_lookup_name;
                dbg_callrec_n += 1;
            }
            if (frame_count >= MAX_FRAMES) { fail("call stack overflow"); return; }
            const func_desc = compiler.getFunction(obj.func_id);
            // Remove the separate func slot: shift [recv..args] down by one.
            var k: u16 = func_slot;
            while (k + 1 < sp) : (k += 1) stack[k] = stack[k + 1];
            sp -= 1;
            const new_bp: u16 = func_slot; // now holds receiver (this)
            checkFrameOverlap(new_bp, obj.func_id);
            ctor_is[frame_count] = false;
            frames[frame_count] = .{
                .func_id = obj.func_id,
                .ip = func_desc.code_start,
                .bp = new_bp,
                .closure_obj = obj_idx,
            };
            frame_count += 1;
            const locals_needed = func_desc.local_count;
            prepareUserLocals(new_bp, obj_idx, argc);
            if (obj.func_id == dbg_entry_watch_func and !dbg_entry_captured) {
                dbg_entry_captured = true;
                dbg_entry_bp = new_bp;
                dbg_entry_sp = sp;
                dbg_entry_lc = locals_needed;
            }
            return;
        }
    }

    // Not callable.
    dbg_notcallable += 1;
    recordNotCallable(last_lookup_name);
    if (!dbg_ncm_captured) {
        dbg_ncm_captured = true;
        if (frame_count > 0) { dbg_ncm_func_id = frames[frame_count - 1].func_id; dbg_ncm_ip = frames[frame_count - 1].ip; }
        const recv = stack[recv_slot];
        dbg_ncm_recv_tag = @intFromEnum(recv.tag);
        dbg_ncm_method = last_lookup_name;
        dbg_ncm_recv_name = prev_lookup_name;
        // Snapshot recent lookup path (most-recent first).
        dbg_ncm_ring_n = 0;
        var rj: usize = 0;
        while (rj < lookup_ring.len and rj < lookup_ring_pos) : (rj += 1) {
            const ri = (lookup_ring_pos - 1 - rj) % lookup_ring.len;
            dbg_ncm_ring[dbg_ncm_ring_n] = lookup_ring[ri];
            dbg_ncm_ring_n += 1;
        }
        // Snapshot the opcode ring (oldest->newest) at the failure.
        dbg_ncm_op_n = 0;
        var oj: usize = 0;
        const ocount = @min(op_ring.len, op_ring_pos);
        while (oj < ocount) : (oj += 1) {
            const oi = (op_ring_pos - ocount + oj) % op_ring.len;
            dbg_ncm_op_ring[dbg_ncm_op_n] = op_ring[oi];
            dbg_ncm_op_ip[dbg_ncm_op_n] = op_ring_ip[oi];
            dbg_ncm_op_n += 1;
        }
        // Freeze the last get_upval state at the ncm moment.
        dbg_ncm_uv_func = dbg_lastuv_func;
        dbg_ncm_uv_idx = dbg_lastuv_idx;
        dbg_ncm_uv_closed = dbg_lastuv_closed;
        dbg_ncm_uv_addr = dbg_lastuv_addr;
        dbg_ncm_uv_stackval = if (dbg_lastuv_addr != objects.NO_UPVAL_ADDR and dbg_lastuv_addr < MAX_STACK) @intFromEnum(stack[dbg_lastuv_addr].tag) else 255;
        if (recv.tag == .object or recv.tag == .array) {
            const ridx: u32 = recv.data.obj_idx;
            dbg_ncm_recv_objidx = ridx;
            dbg_ncm_recv_wasnullset = objects.dbgObjHasNullProto(ridx);
            dbg_ncm_recv_objtype = @intFromEnum(objects.objTypeOf(ridx));
            dbg_ncm_recv_proto = objects.getObjectPrototypeIdx(ridx);
            dbg_ncm_recv_arrlen = objects.arrayLength(ridx);
            // Does anything in the prototype chain have `concat` (own data/getter)?
            dbg_ncm_proto_has_concat = 0;
            { var cur = ridx; var depth: u8 = 0;
              while (cur != objects.NULL_OBJ and depth < 16) : (depth += 1) {
                const k = objects.dbgOwnPropKind(cur, last_lookup_name);
                if (k != 0) { dbg_ncm_proto_has_concat = k; break; }
                cur = objects.getObjectPrototypeIdx(cur);
              } }
            const pc = objects.ownPropCount(ridx);
            var i: u16 = 0;
            while (i < pc and dbg_ncm_prop_count < dbg_ncm_props.len) : (i += 1) {
                dbg_ncm_props[dbg_ncm_prop_count] = objects.ownPropNameAt(ridx, i);
                dbg_ncm_prop_count += 1;
            }
            if (last_lookup_name != 0) dbg_ncm_method_present = objects.hasOwnProperty(ridx, last_lookup_name);
        }
    }
    // ── Push-specific capture: when `t.push` fails, record exactly what `t` is
    // (tag/objType/arrayLength/proto) so we can tell array-stored-as-object vs
    // genuinely-wrong-value. Fires on the FIRST push failure only.
    if (!dbg_pushfail_captured and eql(values.getString(last_lookup_name), "push")) {
        dbg_pushfail_captured = true;
        const prv = stack[recv_slot];
        dbg_pushfail_recv_tag = @intFromEnum(prv.tag);
        if (prv.tag == .string) {
            dbg_pushfail_str_idx = prv.data.str_idx;
            const s = values.getString(prv.data.str_idx);
            const cn = @min(s.len, dbg_pushfail_str.len);
            @memcpy(dbg_pushfail_str[0..cn], s[0..cn]);
            dbg_pushfail_str_len = cn;
        }
        if (prv.tag == .object or prv.tag == .array) {
            const pidx = prv.data.obj_idx;
            dbg_pushfail_recv_obj = pidx;
            dbg_pushfail_recv_objtype = @intFromEnum(objects.objTypeOf(pidx));
            dbg_pushfail_recv_arrlen = objects.arrayLength(pidx);
            dbg_pushfail_recv_proto = objects.getObjectPrototypeIdx(pidx);
            dbg_pushfail_recv_propcount = objects.ownPropCount(pidx);
            dbg_pushfail_arrayproto = objects.getArrayProto();
            // Does the prototype chain resolve `push` as a data/getter prop?
            var cur = pidx; var depth: u8 = 0;
            while (cur != objects.NULL_OBJ and depth < 16) : (depth += 1) {
                const k = objects.dbgOwnPropKind(cur, last_lookup_name);
                if (k != 0) { dbg_pushfail_proto_has_push = k; dbg_pushfail_push_owner = cur; break; }
                cur = objects.getObjectPrototypeIdx(cur);
            }
        }
        if (frame_count > 0) {
            dbg_pushfail_func = frames[frame_count - 1].func_id;
            dbg_pushfail_ip = frames[frame_count - 1].ip;
            dbg_pushfail_485_bp = frames[frame_count - 1].bp;
            dbg_pushfail_485_lc = compiler.getFunction(frames[frame_count - 1].func_id).local_count;
            // Capture closure 485's upvalues (t should be uv0). Report count,
            // and for uv0: closed?/addr/value-tag — to tell capture bug vs
            // v()-returned-wrong-value.
            const clo = frames[frame_count - 1].closure_obj;
            const uvc = objects.closureUpvalCount(clo);
            dbg_pushfail_uvcount = uvc;
            var ui: u16 = 0;
            while (ui < uvc and ui < 8) : (ui += 1) {
                var uv: Value = Value.UNDEFINED;
                const closed = objects.isClosureUpvalClosed(clo, ui);
                if (closed) uv = objects.getClosureUpvalClosedVal(clo, ui)
                else { const a = objects.getClosureUpvalAddr(clo, ui); dbg_pushfail_uv_addr[ui] = a; if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) uv = stack[a]; }
                dbg_pushfail_uv_tag[ui] = @intFromEnum(uv.tag);
                dbg_pushfail_uv_closed[ui] = if (closed) 1 else 0;
            }
            // Find enclosing func-483 frame and read its locals around `t` (idx 8).
            var fi: u16 = frame_count;
            while (fi > 0) : (fi -= 1) {
                if (frames[fi - 1].func_id == 483) {
                    const b483 = frames[fi - 1].bp;
                    dbg_pushfail_483_bp = b483;
                    var li: u16 = 0;
                    while (li < 10) : (li += 1) {
                        const sa: u32 = @as(u32, b483) + li;
                        const lv = if (sa < MAX_STACK) stack[sa] else Value.UNDEFINED;
                        dbg_pushfail_483_local_tag[li] = @intFromEnum(lv.tag);
                        dbg_pushfail_483_local_num[li] = if (lv.tag == .number) lv.data.number else -987654.0;
                    }
                    // x = L2 (bank), g = L3, Y = L4. Record their obj indices.
                    const xv = stack[b483 + 2];
                    dbg_pushfail_483_x_obj = if (xv.tag == .object or xv.tag == .array) xv.data.obj_idx else 0xFFFFFFFF;
                    const gv2 = stack[b483 + 3];
                    dbg_pushfail_483_g_obj = if (gv2.tag == .object or gv2.tag == .array) gv2.data.obj_idx else 0xFFFFFFFF;
                    break;
                }
            }
        }
    }
    sp = func_slot;
    // JS: calling a non-callable method throws "recv.method is not a function".
    // BotGuard deliberately triggers this (e.g. `Y.apply()` with a non-fn apply)
    // to encode the error into its transcript; silently returning undefined
    // desynced the error budget + register decode. Now that eval lexical scope
    // is correct, the remaining non-callable calls are genuine deliberate errors.
    throwNotAFunctionMethod(prev_lookup_name, last_lookup_name);
    _ = &dbg_throw_not_callable;
}

fn isArrayIterMethod(func_id: u16) bool {
    return func_id == builtins.N_ARR_FOR_EACH or func_id == builtins.N_ARR_MAP or
        func_id == builtins.N_ARR_FILTER or func_id == builtins.N_ARR_REDUCE or
        func_id == builtins.N_ARR_FIND or func_id == builtins.N_ARR_SOME or
        func_id == builtins.N_ARR_EVERY;
}

/// Execute an array iteration method, invoking `cb` for each element.
/// forEach -> undefined; map -> new array; filter -> filtered array;
/// reduce -> accumulator (arg2 = initial value); find -> first match;
/// some/every -> boolean.
fn arrayIterMethod(func_id: u16, recv: Value, cb: Value, arg2: Value) Value {
    if (recv.tag != .object and recv.tag != .array) return Value.UNDEFINED;
    const arr: u32 = recv.data.obj_idx;
    const len = objects.arrayLength(arr);

    if (func_id == builtins.N_ARR_MAP) {
        const out = objects.createArray(len);
        var i: u32 = 0;
        while (i < len and !callbackAborted()) : (i += 1) {
            const el = objects.getArrayElement(arr, i);
            const r = callValueSync(cb, arg2, el, Value.number(@floatFromInt(i)), recv, 3);
            if (callbackAborted()) return Value.UNDEFINED;
            objects.setArrayElement(out, i, r);
        }
        return Value.object(out);
    }
    if (func_id == builtins.N_ARR_FILTER) {
        const out = objects.createArray(0);
        var oi: u32 = 0;
        var i: u32 = 0;
        while (i < len and !callbackAborted()) : (i += 1) {
            const el = objects.getArrayElement(arr, i);
            const r = callValueSync(cb, arg2, el, Value.number(@floatFromInt(i)), recv, 3);
            if (r.isTruthy()) { objects.setArrayElement(out, oi, el); oi += 1; }
        }
        return Value.object(out);
    }
    if (func_id == builtins.N_ARR_REDUCE) {
        var acc = arg2; // initial value (if provided)
        var i: u32 = 0;
        // If no initial value was passed (arg2 undefined), seed with element 0.
        if (arg2.tag == .undefined and len > 0) { acc = objects.getArrayElement(arr, 0); i = 1; }
        while (i < len and !callbackAborted()) : (i += 1) {
            const el = objects.getArrayElement(arr, i);
            acc = callValueSync(cb, Value.UNDEFINED, acc, el, Value.number(@floatFromInt(i)), 3);
        }
        return acc;
    }
    if (func_id == builtins.N_ARR_FIND) {
        var i: u32 = 0;
        while (i < len and !callbackAborted()) : (i += 1) {
            const el = objects.getArrayElement(arr, i);
            const r = callValueSync(cb, arg2, el, Value.number(@floatFromInt(i)), recv, 3);
            if (r.isTruthy()) return el;
        }
        return Value.UNDEFINED;
    }
    if (func_id == builtins.N_ARR_SOME) {
        var i: u32 = 0;
        while (i < len and !callbackAborted()) : (i += 1) {
            const el = objects.getArrayElement(arr, i);
            const r = callValueSync(cb, arg2, el, Value.number(@floatFromInt(i)), recv, 3);
            if (r.isTruthy()) return Value.TRUE;
        }
        return Value.FALSE;
    }
    if (func_id == builtins.N_ARR_EVERY) {
        var i: u32 = 0;
        while (i < len and !callbackAborted()) : (i += 1) {
            const el = objects.getArrayElement(arr, i);
            const r = callValueSync(cb, arg2, el, Value.number(@floatFromInt(i)), recv, 3);
            if (!r.isTruthy()) return Value.FALSE;
        }
        return Value.TRUE;
    }
    // forEach
    var i: u32 = 0;
    while (i < len and !callbackAborted()) : (i += 1) {
        const el = objects.getArrayElement(arr, i);
        _ = callValueSync(cb, arg2, el, Value.number(@floatFromInt(i)), recv, 3);
    }
    return Value.UNDEFINED;
}

/// Handle generic Function.prototype.call/apply/bind and bound functions.
/// Stack at entry: [invoker][arg0][arg1]... with sp past the args.
///   .call(thisArg, a, b)  -> target(a, b) with this=thisArg
///   .apply(thisArg, argsArray) -> target(...argsArray) with this=thisArg
///   .bind(...) -> captures receiver and leading arguments
fn fnMethodCall(kind: u16, invoker_idx: u32, argc: u8, receiver: ?Value) void {
    const target = if (kind == builtins.N_FN_BOUND) objects.getProperty(invoker_idx, values.internString("__target__")) else receiver orelse Value.UNDEFINED;
    if (target.tag != .function) {
        throwTypeErrorMsg("Function method requires a callable receiver");
        return;
    }

    if (kind == builtins.N_FN_BIND) {
        // Materialize a bound function: f.bind(thisArg, ...boundArgs).
        // Capture thisArg (first arg) and the remaining boundArgs into an array,
        // and produce a N_FN_BOUND invoker that, when called, dispatches `target`
        // with this=thisArg and boundArgs prepended. Real JS bind semantics —
        // BotGuard's register getters use `Array.prototype.pop.bind(stack)`.
        const bthis = if (argc >= 1) stack[sp - argc] else Value.UNDEFINED;
        const barr = objects.createArray(0);
        var bi: u8 = 1;
        var bn: u32 = 0;
        while (bi < argc) : (bi += 1) {
            objects.setArrayElement(barr, bn, stack[sp - argc + bi]);
            bn += 1;
        }
        const bound = objects.createFunction(builtins.N_FN_BOUND);
        objects.setProperty(bound, values.internString("__target__"), target);
        objects.setProperty(bound, values.internString("__boundThis__"), bthis);
        objects.setProperty(bound, values.internString("__boundArgs__"), Value.object(barr));
        sp -= (argc + 1);
        push(Value.function(bound));
        return;
    }

    if (kind == builtins.N_FN_BOUND) {
        // Invoke a materialized bound function: call target with this=boundThis
        // and boundArgs ++ callArgs. The call args are stack[sp-argc .. sp].
        const bthis = objects.getProperty(invoker_idx, values.internString("__boundThis__"));
        const bargs_v = objects.getProperty(invoker_idx, values.internString("__boundArgs__"));
        var combined: [64]Value = undefined;
        var cn: u8 = 0;
        if (bargs_v.tag == .array or bargs_v.tag == .object) {
            const balen = objects.arrayLength(@intCast(bargs_v.data.obj_idx));
            if (balen + argc > combined.len) { throwRangeErrorMsg("bound argument capacity exceeded"); return; }
            var k: u32 = 0;
            while (k < balen and cn < 64) : (k += 1) {
                combined[cn] = objects.getArrayElement(@intCast(bargs_v.data.obj_idx), k);
                cn += 1;
            }
        }
        var ai: u8 = 0;
        while (ai < argc and cn < 64) : (ai += 1) {
            combined[cn] = stack[sp - argc + ai];
            cn += 1;
        }
        sp -= (argc + 1);
        const btobj = objects.getObject(target.data.func_idx);
        if (btobj.func_id >= 0xF000) {
            if (builtins.isFnMethod(btobj.func_id) or builtins.isVmIntrinsic(btobj.func_id) or isArrayIterMethod(btobj.func_id)) {
                const result = callExportedN(target, bthis, combined[0..cn]);
                if (callbackAborted()) return;
                push(result);
                return;
            }
            if (builtins.nativeIgnoresReceiver(btobj.func_id)) {
                const result = builtins.callNative(btobj.func_id, combined[0..cn], cn);
                if (checkNativeThrow()) return;
                push(result);
                return;
            }
            // Native target: prepend boundThis as the receiver (args[0]).
            var recv2: [65]Value = undefined;
            recv2[0] = bthis;
            var ci2: u8 = 0;
            while (ci2 < cn and ci2 < 64) : (ci2 += 1) recv2[ci2 + 1] = combined[ci2];
            push(builtins.callNative(btobj.func_id, recv2[0 .. cn + 1], cn + 1));
        } else {
            // User target: build a frame [boundThis][combined args][locals].
            if (frame_count >= MAX_FRAMES) { fail("call stack overflow"); push(Value.UNDEFINED); return; }
            const bd = compiler.getFunction(btobj.func_id);
            const nbp = sp;
            checkFrameOverlap(@intCast(nbp), btobj.func_id);
            push(bthis);
            var ci3: u8 = 0;
            while (ci3 < cn) : (ci3 += 1) push(combined[ci3]);
            ctor_is[frame_count] = false;
            frames[frame_count] = .{ .func_id = btobj.func_id, .ip = bd.code_start, .bp = @intCast(nbp), .closure_obj = target.data.func_idx };
            frame_count += 1;
            prepareUserLocals(@intCast(nbp), target.data.func_idx, cn);
        }
        return;
    }

    const target_obj_idx: u32 = target.data.func_idx;
    const tobj = objects.getObject(target_obj_idx);
    const func_desc = compiler.getFunction(tobj.func_id);

    // thisArg is the first argument (or undefined if none).
    const this_arg = if (argc >= 1) stack[sp - argc] else Value.UNDEFINED;

    // Determine real arguments passed to the target.
    // .call: args are stack[sp-argc+1 .. sp]
    // .apply: a single array whose elements are the args.
    //
    // NOTE: `.apply(this, bigArray)` can spread a LARGE array — BotGuard's base64
    // encoder does `String.fromCharCode.apply(null, byteChunk)` with chunks up to
    // 8192 elements. A 64-arg cap truncated the spread, so the final base64
    // response was cut to ~88 bytes (should be ~2891). Use a large module-level
    // scratch buffer (fnapply_args) so the full array is forwarded. The call
    // convention's u8 argc still bounds USER targets (255), but the base64 case
    // targets a NATIVE (fromCharCode) which we dispatch by slice length below.
    var real_argc: u32 = if (kind == builtins.N_FN_APPLY) 0 else if (argc > 0) argc - 1 else 0;
    var argument_list = Value.UNDEFINED;
    if (kind == builtins.N_FN_APPLY) {
        if (argc >= 2) {
            const arr = stack[sp - argc + 1];
            argument_list = arr;
            if (arr.tag == .array or arr.tag == .object or arr.tag == .function) {
                // apply accepts any array-like object, including an ordinary
                // arguments object. Its length/index properties need normal
                // reads so mapped values and accessors remain observable.
                const lv = getPropFromValue(arr, values.internString("length"));
                if (callbackAborted()) return;
                const ln = lv.toNumber();
                if (callbackAborted()) return;
                const argument_length = if (ln > 0) @trunc(ln) else 0;
                if (argument_length > 8192) { throwRangeErrorMsg("apply argument capacity exceeded"); return; }
                real_argc = @intFromFloat(argument_length);
            } else if (arr.tag != .undefined and arr.tag != .null_val) { throwTypeErrorMsg("apply requires an array-like object"); return; }
        }
    }
    const saved_apply_used = fnapply_used;
    if (real_argc + 1 > fnapply_storage.len - fnapply_used) { throwRangeErrorMsg("nested apply argument capacity exceeded"); return; }
    fnapply_used += real_argc + 1;
    defer fnapply_used = saved_apply_used;
    const fnapply_recv = fnapply_storage[saved_apply_used..fnapply_used];
    const fnapply_args = fnapply_recv[1..];
    fnapply_recv[0] = this_arg;
    if (kind == builtins.N_FN_APPLY) {
        for (0..real_argc) |k| {
            fnapply_args[k] = getElemFromValue(argument_list, Value.number(@floatFromInt(k)));
            if (callbackAborted()) return;
        }
    } else {
        // .call — copy args after thisArg.
        var k: u8 = 1;
        while (k < argc) : (k += 1) fnapply_args[k - 1] = stack[sp - argc + k];
    }

    // Native target: dispatch through callNative. Native methods use args[0]
    // as the receiver (`this`), so prepend this_arg — for `X.call(thisArg,...)`
    // and `X.apply(thisArg,[...])` the native must see thisArg as its receiver
    // (e.g. Object.prototype.toString.call(arr) must inspect arr).
    if (tobj.func_id >= 0xF000) {
        if (builtins.isFnMethod(tobj.func_id)) {
            const base = sp - (argc + 1);
            const result = callExportedN(target, this_arg, fnapply_args[0..real_argc]);
            if (callbackAborted()) return;
            sp = base;
            push(result);
            return;
        }
        if (builtins.isVmIntrinsic(tobj.func_id)) {
            if (real_argc > 255) { fail("intrinsic apply argument capacity exceeded"); return; }
            sp -= (argc + 1);
            push(target);
            for (fnapply_args[0..real_argc]) |arg| push(arg);
            const saved_direct = eval_is_direct;
            eval_is_direct = false; // eval.call/apply is always indirect
            evalIntrinsic(tobj.func_id, @intCast(real_argc));
            eval_is_direct = saved_direct;
            return;
        }
        if (isArrayIterMethod(tobj.func_id)) {
            const callback = if (real_argc > 0) fnapply_args[0] else Value.UNDEFINED;
            const arg2 = if (real_argc > 1) fnapply_args[1] else Value.UNDEFINED;
            const result = arrayIterMethod(tobj.func_id, this_arg, callback, arg2);
            if (operation_aborted) return;
            sp -= (argc + 1);
            push(result);
            return;
        }
        if (dbg_disable_call_recv or builtins.nativeIgnoresReceiver(tobj.func_id)) {
            const na: u32 = @min(real_argc, @as(u32, 65535));
            const result = builtins.callNative(tobj.func_id, fnapply_args[0..na], @intCast(@min(na, 255)));
            if (operation_aborted) return;
            sp -= (argc + 1);
            if (checkNativeThrow()) return;
            push(result);
            return;
        }
        // Prepend this_arg as args[0]; forward the full spread (bounded by the
        // scratch buffer) so large `.apply` arrays reach the native intact.
        const total: u32 = real_argc + 1;
        const result = builtins.callNative(tobj.func_id, fnapply_recv[0..total], @intCast(@min(total, 255)));
        if (operation_aborted) return;
        sp -= (argc + 1);
        if (checkNativeThrow()) return;
        push(result);
        return;
    }

    // User target: build a fresh frame. Pop the whole [invoker...args] region,
    // then lay out [this][arg0..argN][locals] and jump to the target.
    sp -= (argc + 1);
    if (frame_count >= MAX_FRAMES) { fail("call stack overflow"); push(Value.UNDEFINED); return; }
    const new_bp = sp;
    checkFrameOverlap(@intCast(new_bp), tobj.func_id);
    push(this_arg); // slot 0 = this
    { var i: u32 = 0; while (i < real_argc) : (i += 1) push(fnapply_args[i]); }

    ctor_is[frame_count] = false;
    frames[frame_count] = .{
        .func_id = tobj.func_id,
        .ip = func_desc.code_start,
        .bp = @intCast(new_bp),
        .closure_obj = target_obj_idx,
    };
    frame_count += 1;
    prepareUserLocals(@intCast(new_bp), target_obj_idx, real_argc);
    if (tobj.func_id == dbg_entry_watch_func and !dbg_entry_captured) {
        dbg_entry_captured = true;
        dbg_entry_bp = @intCast(new_bp);
        dbg_entry_sp = sp;
        dbg_entry_lc = func_desc.local_count;
        dbg_entry_via_call = true;
        dbg_entry_argc = argc;
        dbg_entry_real_argc = @intCast(@min(real_argc, 255));
        captureEntryParams(@intCast(new_bp));
    }
}
pub var dbg_entry_via_call: bool = false;
pub var dbg_entry_argc: u8 = 0;
pub var dbg_entry_real_argc: u8 = 0;
pub var dbg_entry_caller_func: u16 = 0xFFFF;
pub var dbg_entry_caller_ip: u32 = 0;

// ── Callee-load provenance (which op/operand produced the watched callee) ──
// When the watched func is first entered via the plain `.call` path, we snapshot
// the caller's opcode ring (op + ip) so we can see the exact load sequence that
// pushed the callee value onto the stack, plus a decode of the callee-producing
// op's operand (slot / upval idx / elem key / prop name).
pub var dbg_calleeprov_captured: bool = false;
pub var dbg_calleeprov_op: [24]u8 = [_]u8{0} ** 24;
pub var dbg_calleeprov_ip: [24]u32 = [_]u32{0} ** 24;
pub var dbg_calleeprov_n: usize = 0;
// The op that actually produced the callee value (argc+1 pushes before .call).
pub var dbg_calleeprov_src_op: u8 = 255;
pub var dbg_calleeprov_src_ip: u32 = 0;
pub var dbg_calleeprov_src_operand: u32 = 0xFFFFFFFF; // slot/upval-idx/const-idx
pub var dbg_calleeprov_src_kind: u8 = 0; // 0=unknown 1=local 2=upval 3=elem 4=prop 5=global
// For get_elem: the object index + numeric/string key that produced the callee.
pub var dbg_calleeprov_elem_objidx: u32 = 0xFFFFFFFF;
pub var dbg_calleeprov_elem_keynum: f64 = 0;
pub var dbg_calleeprov_elem_keytag: u8 = 255;
pub var dbg_calleeprov_elem_keystr: [48]u8 = [_]u8{0} ** 48;
pub var dbg_calleeprov_elem_keystr_len: usize = 0;
// For get_prop/get_global: the property/name string.
pub var dbg_calleeprov_name: [48]u8 = [_]u8{0} ** 48;
pub var dbg_calleeprov_name_len: usize = 0;
// For get_upval: the resolved closure cell state.
pub var dbg_calleeprov_uv_closed: bool = false;
pub var dbg_calleeprov_uv_addr: u32 = 0;
pub var dbg_calleeprov_uv_closure: u32 = 0;
// The resolved callee object index + func_id that we are about to enter.
pub var dbg_calleeprov_callee_objidx: u32 = 0xFFFFFFFF;
pub var dbg_calleeprov_callee_funcid: u16 = 0xFFFF;

pub fn dbgCalleeProvCount() usize { return dbg_calleeprov_n; }
pub fn dbgCalleeProvOpName(i: usize) []const u8 {
    if (i >= dbg_calleeprov_n) return "";
    return @tagName(@as(Op, @enumFromInt(dbg_calleeprov_op[i])));
}
pub fn dbgCalleeProvOpIp(i: usize) u32 { return if (i < dbg_calleeprov_n) dbg_calleeprov_ip[i] else 0; }
pub fn dbgCalleeProvSrcOpName() []const u8 {
    if (dbg_calleeprov_src_op == 255) return "(none)";
    return @tagName(@as(Op, @enumFromInt(dbg_calleeprov_src_op)));
}
pub fn dbgCalleeProvElemKeyStr() []const u8 { return dbg_calleeprov_elem_keystr[0..dbg_calleeprov_elem_keystr_len]; }
pub fn dbgCalleeProvName() []const u8 { return dbg_calleeprov_name[0..dbg_calleeprov_name_len]; }

/// Snapshot the caller's op ring + decode the callee-producing op just before a
/// `.call` that resolved to the watched function. `argc` args + 1 callee were
/// pushed; the callee-producing op is the (argc+1)-th value-pushing op back, but
/// the simplest robust signal is: the callee sits at stack[sp-1-argc], and the
/// op that pushed it is recorded in the ring. We scan the ring backwards over
/// the just-executed .call to find the load op that targeted the callee slot.
fn captureCalleeProvenance(argc: u8, callee_val: Value, callee_obj_idx: u32, callee_func_id: u16) void {
    if (dbg_calleeprov_captured) return;
    dbg_calleeprov_captured = true;
    dbg_calleeprov_callee_objidx = callee_obj_idx;
    dbg_calleeprov_callee_funcid = callee_func_id;
    // Snapshot the CALLER frame's closure upvalue map (the watched frame is
    // already pushed at frame_count-1, so the caller is frame_count-2).
    if (frame_count >= 2) snapshotCallerUpvals(frames[frame_count - 2].closure_obj);

    // Copy the tail of the op ring (last up to 24 ops) for context.
    const want = @min(op_ring.len, @min(op_ring_pos, dbg_calleeprov_op.len));
    dbg_calleeprov_n = 0;
    var oj: usize = 0;
    while (oj < want) : (oj += 1) {
        const oi = (op_ring_pos - want + oj) % op_ring.len;
        dbg_calleeprov_op[dbg_calleeprov_n] = op_ring[oi];
        dbg_calleeprov_ip[dbg_calleeprov_n] = op_ring_ip[oi];
        dbg_calleeprov_n += 1;
    }

    // The callee value is at stack[sp-1-argc]. Identify what produced it by
    // decoding the op at the ring position that pushed it. On the stack the
    // push order is: [callee][arg0]..[arg{argc-1}]. Counting value-producing
    // ops from the .call backwards is fragile (spread/dup), so instead decode
    // directly from the callee value + the load op whose operand we can read.
    // Walk the ring backwards (skipping the current .call at the newest slot)
    // and find the FIRST load-style op; that is the arg-producing chain. To get
    // the CALLEE producer we need the load whose result equals the callee: we
    // approximate by taking the load op that is (argc+1) load-ops back. But the
    // most reliable is to re-read the bytecode operand of each get_* op in the
    // ring and match its produced value against callee_val — done below.
    _ = callee_val;

    const bc = compiler.getBytecode();
    // Find, among the ring entries, the load op that produced the callee. The
    // callee was pushed first, so it is the OLDEST load in the current call's
    // argument-building sequence. Scan forward from the oldest ring entry that
    // belongs to the caller frame; the first get_* op is the callee load.
    // (BotGuard emits: <load callee>, <load arg0>..., call.)
    // We locate the callee load as the (n - (argc+1) - 1)-th ... instead, be
    // explicit: the .call is the newest entry (n-1). The argc args were each
    // produced by one or more ops; the callee producer is the load-op at ring
    // index that leaves exactly argc values above it before the call. We record
    // the nearest load op that is a function-producing get and matches.
    // Practical decode: take the ring entry (n-1) = call; scan back to find the
    // load op sequence. We record the op at index (n-1-(argc+1)) as the best
    // guess of the callee producer and decode its operand.
    if (dbg_calleeprov_n >= 2) {
        // best-guess index of the callee producer
        var guess: isize = @as(isize, @intCast(dbg_calleeprov_n)) - 1; // .call
        guess -= 1; // step onto the op right before .call
        // Walk back argc "load/const" ops to reach the callee producer.
        var remaining: isize = argc;
        while (guess >= 0 and remaining > 0) : (guess -= 1) {
            const o: Op = @enumFromInt(dbg_calleeprov_op[@intCast(guess)]);
            if (isValueProducingLoad(o)) remaining -= 1;
        }
        // Now walk back over any non-load glue ops to the actual load.
        while (guess >= 0) {
            const o: Op = @enumFromInt(dbg_calleeprov_op[@intCast(guess)]);
            if (isValueProducingLoad(o)) break;
            guess -= 1;
        }
        if (guess >= 0) {
            const src_op_byte = dbg_calleeprov_op[@intCast(guess)];
            const src_ip = dbg_calleeprov_ip[@intCast(guess)];
            dbg_calleeprov_src_op = src_op_byte;
            dbg_calleeprov_src_ip = src_ip;
            decodeCalleeLoadOp(@enumFromInt(src_op_byte), src_ip, bc);
        }
    }
}

fn isValueProducingLoad(o: Op) bool {
    return switch (o) {
        .get_local, .get_upval, .get_global, .get_global_safe, .get_prop, .get_elem, .get_optional, .get_elem_optional, .load_const, .this_val, .make_func, .dup => true,
        else => false,
    };
}

/// Decode the operand of the callee-producing load op by re-reading the caller's
/// bytecode at src_ip (the op byte is at src_ip; operand follows).
fn decodeCalleeLoadOp(o: Op, src_ip: u32, bc: []const u8) void {
    switch (o) {
        .get_local => {
            dbg_calleeprov_src_kind = 1;
            if (src_ip + 2 < bc.len) {
                var ip: u32 = src_ip + 1;
                dbg_calleeprov_src_operand = readU16(bc, &ip);
            }
        },
        .get_upval => {
            dbg_calleeprov_src_kind = 2;
            if (src_ip + 2 < bc.len) {
                var ip: u32 = src_ip + 1;
                const idx = readU16(bc, &ip);
                dbg_calleeprov_src_operand = idx;
                // Resolve the CALLER frame's closure cell state. By the time this
                // runs the callee (watched) frame is already pushed at
                // frames[frame_count-1], so the load site is frames[frame_count-2].
                if (frame_count >= 2) {
                    const cf = &frames[frame_count - 2];
                    if (cf.closure_obj != objects.NULL_OBJ) {
                        dbg_calleeprov_uv_closed = objects.isClosureUpvalClosed(cf.closure_obj, idx);
                        dbg_calleeprov_uv_addr = objects.getClosureUpvalAddr(cf.closure_obj, idx);
                        dbg_calleeprov_uv_closure = cf.closure_obj;
                    }
                }
            }
        },
        .get_global, .get_global_safe => {
            dbg_calleeprov_src_kind = 5;
            if (src_ip + 2 < bc.len) {
                var ip: u32 = src_ip + 1;
                const nidx = readU16(bc, &ip);
                dbg_calleeprov_src_operand = nidx;
                copyConstName(nidx);
            }
        },
        .get_prop, .get_optional => {
            dbg_calleeprov_src_kind = 4;
            if (src_ip + 2 < bc.len) {
                var ip: u32 = src_ip + 1;
                const nidx = readU16(bc, &ip);
                dbg_calleeprov_src_operand = nidx;
                copyConstName(nidx);
            }
        },
        .get_elem, .get_elem_optional => {
            dbg_calleeprov_src_kind = 3;
            // get_elem has no operand; key + obj were on the stack. Recover the
            // key/obj from the current stack top region is not possible here
            // (already popped). Instead capture from the last get_elem seen by
            // the dedicated get_elem probe (dbg_lastgetelem_*).
            dbg_calleeprov_elem_objidx = dbg_lastgetelem_objidx;
            dbg_calleeprov_elem_keynum = dbg_lastgetelem_keynum;
            dbg_calleeprov_elem_keytag = dbg_lastgetelem_keytag;
            const ks = dbg_lastgetelem_keystr[0..dbg_lastgetelem_keystr_len];
            const kn = @min(ks.len, dbg_calleeprov_elem_keystr.len);
            @memcpy(dbg_calleeprov_elem_keystr[0..kn], ks[0..kn]);
            dbg_calleeprov_elem_keystr_len = kn;
        },
        else => { dbg_calleeprov_src_kind = 0; },
    }
}

fn copyConstName(nidx: u16) void {
    const sidx = constToStringIdx(nidx);
    const s = values.getString(sidx);
    const n = @min(s.len, dbg_calleeprov_name.len);
    @memcpy(dbg_calleeprov_name[0..n], s[0..n]);
    dbg_calleeprov_name_len = n;
}

// Snapshot of the caller closure's upvalue map at the bad call: for each upval
// slot, its backing cell index, closed flag, addr, and (if the cell value is a
// function) its func_id. Reveals cell aliasing (two slots sharing one cell).
pub var dbg_callerupv_n: u16 = 0;
pub var dbg_callerupv_cell: [64]u32 = [_]u32{0xFFFFFFFF} ** 64;
pub var dbg_callerupv_closed: [64]bool = [_]bool{false} ** 64;
pub var dbg_callerupv_addr: [64]u32 = [_]u32{0xFFFFFFFF} ** 64;
pub var dbg_callerupv_valfid: [64]u16 = [_]u16{0xFFFF} ** 64; // 0xFFFF = not a function
pub var dbg_callerupv_valtag: [64]u8 = [_]u8{255} ** 64;
pub fn dbgCallerUpvN() u16 { return dbg_callerupv_n; }
pub fn dbgCallerUpvCell(i: usize) u32 { return if (i < 64) dbg_callerupv_cell[i] else 0xFFFFFFFF; }
pub fn dbgCallerUpvClosed(i: usize) bool { return if (i < 64) dbg_callerupv_closed[i] else false; }
pub fn dbgCallerUpvAddr(i: usize) u32 { return if (i < 64) dbg_callerupv_addr[i] else 0xFFFFFFFF; }
pub fn dbgCallerUpvValFid(i: usize) u16 { return if (i < 64) dbg_callerupv_valfid[i] else 0xFFFF; }
pub fn dbgCallerUpvValTag(i: usize) u8 { return if (i < 64) dbg_callerupv_valtag[i] else 255; }

fn snapshotCallerUpvals(caller_closure: u32) void {
    if (caller_closure == objects.NULL_OBJ) return;
    const nu = objects.dbgClosureNUpvals(caller_closure);
    const lim: u16 = @min(nu, 64);
    dbg_callerupv_n = lim;
    var i: u16 = 0;
    while (i < lim) : (i += 1) {
        const ci = objects.dbgClosureCellIdx(caller_closure, i);
        dbg_callerupv_cell[i] = ci;
        if (ci != objects.NO_CELL) {
            dbg_callerupv_closed[i] = objects.dbgCellClosed(ci);
            dbg_callerupv_addr[i] = objects.dbgCellAddr(ci);
            // Resolve the cell's current value: closed -> cell_val; open -> stack.
            var v = objects.dbgCellVal(ci);
            if (!dbg_callerupv_closed[i]) {
                const a = objects.dbgCellAddr(ci);
                if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) v = stack[a];
            }
            dbg_callerupv_valtag[i] = @intFromEnum(v.tag);
            if (v.tag == .function) {
                const fo = objects.getObject(v.data.func_idx);
                dbg_callerupv_valfid[i] = fo.func_id;
            }
        }
    }
}

// O-state probe: watch a specific func's state-variable slot and record the
// first N numeric writes (the state-machine transition trace).
pub var dbg_ostate_func: u16 = 0xFFFF;
pub var dbg_ostate_slot: u16 = 0xFFFF;
pub var dbg_ostate_val: [8192]f64 = [_]f64{0} ** 8192;
pub var dbg_ostate_ip: [8192]u32 = [_]u32{0} ** 8192;
pub var dbg_ostate_r166: [8192]i32 = [_]i32{-1} ** 8192;
pub fn dbgOStateR166(i: usize) i32 { return if (i < dbg_ostate_n) dbg_ostate_r166[i] else -1; }
pub var dbg_ostate_n: usize = 0;
pub fn dbgOStateCount() usize { return dbg_ostate_n; }
pub fn dbgOStateVal(i: usize) f64 { return if (i < dbg_ostate_n) dbg_ostate_val[i] else 0; }
pub fn dbgOStateIp(i: usize) u32 { return if (i < dbg_ostate_n) dbg_ostate_ip[i] else 0; }
pub fn dbgOStateEnable(func: u16, slot: u16) void { dbg_ostate_func = func; dbg_ostate_slot = slot; dbg_ostate_n = 0; }
pub var dbg_gt4_watch: bool = false;
pub var dbg_gt4_func: u16 = 0xFFFF;
pub var dbg_gt4_val: [512]f64 = [_]f64{-1} ** 512;
pub var dbg_gt4_ip: [512]u32 = [_]u32{0} ** 512;
pub var dbg_gt4_n: usize = 0;
pub fn dbgGt4Enable(func: u16) void { dbg_gt4_watch = true; dbg_gt4_func = func; dbg_gt4_n = 0; }
pub fn dbgGt4N() usize { return dbg_gt4_n; }
pub fn dbgGt4Val(i: usize) f64 { return if (i < dbg_gt4_n) dbg_gt4_val[i] else -1; }
pub var dbg_dl_func: u16 = 0xFFFF;
pub var dbg_dl_done: bool = false;
pub var dbg_dl_len: u32 = 0;
pub var dbg_dl_vals: [16]f64 = [_]f64{-1} ** 16;
pub fn dbgDlEnable(func: u16) void { dbg_dl_func = func; dbg_dl_done = false; dbg_dl_len = 0; }
pub fn dbgDlLen() u32 { return dbg_dl_len; }
pub fn dbgDlVal(i: usize) f64 { return if (i < 16) dbg_dl_vals[i] else -1; }
pub var execution_limit: u64 = 200_000_000;
pub var dbg_gtrace_on: bool = false;
pub var dbg_type_n: usize = 0;
// Independent development capture; avoids enabling expensive protocol tracing.
pub var debug_typeof_on: bool = false;
pub var dbg_branch_a: Value = Value.UNDEFINED;
pub var dbg_branch_b: Value = Value.UNDEFINED;
pub var dbg_branch_slots: [16]Value = undefined;
pub var dbg_417_n: usize = 0;
pub var dbg_417_values: [32]Value = undefined;
pub var dbg_417_registers: [32]f64 = undefined;
pub var dbg_417_g: [32]usize = undefined;
pub var dbg_property_receiver: Value = Value.UNDEFINED;
pub var dbg_property_key: Value = Value.UNDEFINED;
pub var dbg_property_result: Value = Value.UNDEFINED;
pub var dbg_94_bank: [32]Value = undefined;
pub var dbg_94_cell: [32]Value = undefined;
pub var dbg_417_funcs: [32]u16 = undefined;
pub var dbg_type_gn: [4096]usize = undefined;
pub var dbg_type_func: [4096]u16 = undefined;
pub var dbg_type_name: [4096]u32 = undefined;
pub var dbg_type_value: [4096]Value = undefined;
pub var dbg_type_key: [4096]u32 = undefined;
pub var dbg_type_obj: [4096]u32 = undefined;
pub var dbg_type_callers: [4096][3]u16 = undefined;
pub var dbg_probe_n: usize = 0;
pub var dbg_probe_key: [1024]u32 = undefined;
pub var dbg_probe_gn: [1024]usize = undefined;
pub var dbg_probe_obj: [1024]Value = undefined;
pub var dbg_probe_func: [1024]u16 = undefined;
pub var dbg_gtrace_func: u16 = 0xFFFF;
pub var dbg_gtrace_val: [200000]f64 = undefined;
pub var dbg_gtrace_pos: [200000]f64 = undefined;
pub var dbg_gtrace_cap_keyvals: [5]Value = [_]Value{Value.UNDEFINED} ** 5;
pub var dbg_gtrace_cap_keynums: [5][32]Value = undefined;
pub var dbg_gtrace_cap_keylens: [5]u32 = [_]u32{0} ** 5;
pub var dbg_gtrace_sel: [200000]i32 = undefined;
pub var dbg_gtrace_n: usize = 0;
pub var dbg_gtrace_prefix: ?[]const u8 = null;
pub var dbg_gtrace_pos_slot: u16 = 14;
pub var dbg_gtrace_sel_slot: u16 = 2;
pub fn dbgGTraceEnable(func: u16) void { dbg_gtrace_on = true; dbg_gtrace_func = func; dbg_gtrace_n = 0; }
pub fn dbgGTraceN() usize { return dbg_gtrace_n; }
pub fn dbgGTraceVal(i: usize) f64 { return if (i < dbg_gtrace_n) dbg_gtrace_val[i] else -1234567890123.0; }
pub fn dbgGTracePos(i: usize) f64 { return if (i < dbg_gtrace_n) dbg_gtrace_pos[i] else -1; }
pub fn dbgGTraceSel(i: usize) i32 { return if (i < dbg_gtrace_n) dbg_gtrace_sel[i] else -1; }
pub var dbg_gtrace_cap_idx: usize = 0xFFFFFFFF;
pub var dbg_gtrace_cap_func: [32]u16 = [_]u16{0xFFFF} ** 32;
pub var dbg_gtrace_cap_ip: [32]u32 = [_]u32{0} ** 32;
pub var dbg_gtrace_cap_n: usize = 0;
pub var dbg_gtrace_cap_slots: [32][16]Value = undefined;
pub var dbg_gtrace_cap_upvals: [32][32]Value = undefined;

pub fn dbgGTraceCapSet(idx: usize) void { dbg_gtrace_cap_idx = idx; }
pub fn dbgGTraceCapN() usize { return dbg_gtrace_cap_n; }
pub fn dbgGTraceCapFunc(i: usize) u16 { return if (i < 32) dbg_gtrace_cap_func[i] else 0xFFFF; }
pub fn dbgGTraceCapIp(i: usize) u32 { return if (i < 32) dbg_gtrace_cap_ip[i] else 0; }
// Read-only FIFO diagnostics. The cell getter closes over g; inspect that
// upvalue directly so collecting a trace cannot run challenge code.
const DbgHkRow = struct { kind: u8, gn: usize, result: Value, f: Value, i: Value, flen: u32, ilen: u32, fv: [16]Value, iv: [16]Value };
var dbg_hk_rows: [10000]DbgHkRow = undefined;
var dbg_hk_n: usize = 0;
var dbg_hk_text: [4 * 1024 * 1024]u8 = undefined;
var dbg_hk_text_n: usize = 0;
fn dbgHkCellValue(cell: Value) Value {
    if (cell.tag != .object and cell.tag != .function and cell.tag != .array) return Value.UNDEFINED;
    const getter = objects.getProperty(cell.data.obj_idx, values.internString("create"));
    if (getter.tag != .function) return Value.UNDEFINED;
    const oi = getter.data.obj_idx;
    const fid = objects.closureFuncId(oi);
    var j: u16 = 0;
    while (j < objects.closureUpvalCount(oi)) : (j += 1) {
        const uvn = compiler.funcUpvalName(fid, j);
        if (uvn == 0xFFFFFFFF or !eql(values.getString(uvn), "g")) continue;
        if (objects.isClosureUpvalClosed(oi, j)) return objects.getClosureUpvalClosedVal(oi, j);
        const a = objects.getClosureUpvalAddr(oi, j);
        return if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) stack[a] else Value.UNDEFINED;
    }
    return Value.UNDEFINED;
}
fn dbgHkRecord(kind: u8, bank: Value, result: Value) void {
    if (dbg_hk_n >= dbg_hk_rows.len) return;
    const f = if (bank.tag == .object or bank.tag == .array) dbgHkCellValue(objects.getProperty(bank.data.obj_idx, values.internString("F"))) else Value.UNDEFINED;
    const i = if (bank.tag == .object or bank.tag == .array) dbgHkCellValue(objects.getProperty(bank.data.obj_idx, values.internString("I"))) else Value.UNDEFINED;
    const fa = (f.tag == .array or f.tag == .object) and objects.objTypeOf(f.data.obj_idx) == .array;
    const ia = (i.tag == .array or i.tag == .object) and objects.objTypeOf(i.data.obj_idx) == .array;
    const flen = if (fa) objects.arrayLength(f.data.obj_idx) else 0;
    const ilen = if (ia) objects.arrayLength(i.data.obj_idx) else 0;
    var row = DbgHkRow{ .kind = kind, .gn = dbg_gtrace_n, .result = result, .f = f, .i = i, .flen = flen, .ilen = ilen, .fv = undefined, .iv = undefined };
    for (0..16) |j| {
        row.fv[j] = if (fa and j < flen) objects.getArrayElement(f.data.obj_idx, @intCast(j)) else Value.UNDEFINED;
        row.iv[j] = if (ia and j < ilen) objects.getArrayElement(i.data.obj_idx, @intCast(j)) else Value.UNDEFINED;
    }
    dbg_hk_rows[dbg_hk_n] = row;
    dbg_hk_n += 1;
}
fn dbgHkByte(c: u8) void { if (dbg_hk_text_n < dbg_hk_text.len) { dbg_hk_text[dbg_hk_text_n] = c; dbg_hk_text_n += 1; } }
fn dbgHkNum(v: i64) void {
    if (v < 0) dbgHkByte('-');
    var x: u64 = @intCast(if (v < 0) -v else v);
    if (x == 0) { dbgHkByte('0'); return; }
    var temp: [20]u8 = undefined; var n: usize = 0;
    while (x > 0) { temp[n] = @intCast('0' + x % 10); n += 1; x /= 10; }
    while (n > 0) { n -= 1; dbgHkByte(temp[n]); }
}
fn dbgHkValue(v: Value) void {
    dbgHkNum(@intFromEnum(v.tag)); dbgHkByte(':');
    if (v.tag == .number and v.data.number == v.data.number and v.data.number > -9e18 and v.data.number < 9e18) dbgHkNum(@intFromFloat(v.data.number))
    else if (v.tag == .object or v.tag == .array or v.tag == .function) dbgHkNum(v.data.obj_idx)
    else dbgHkNum(0);
}
pub fn dbgHkTraceText() []const u8 {
    dbg_hk_text_n = 0;
    for (dbg_hk_rows[0..dbg_hk_n]) |row| {
        dbgHkNum(row.kind); dbgHkByte(' '); dbgHkNum(@intCast(row.gn)); dbgHkByte(' '); dbgHkValue(row.result);
        dbgHkByte(' '); dbgHkValue(row.f); dbgHkByte(' '); dbgHkNum(row.flen);
        dbgHkByte(' '); dbgHkValue(row.i); dbgHkByte(' '); dbgHkNum(row.ilen);
        for (row.fv) |v| { dbgHkByte(' '); dbgHkValue(v); }
        for (row.iv) |v| { dbgHkByte(' '); dbgHkValue(v); }
        dbgHkByte('\n');
    }
    return dbg_hk_text[0..dbg_hk_text_n];
}
pub var dbg_hh_watch: bool = false;
pub var dbg_hh_func: u16 = 0xFFFF;
pub var dbg_hh_callee: [4096]u16 = [_]u16{0xFFFF} ** 4096;
pub var dbg_hh_ip: [4096]u32 = [_]u32{0} ** 4096;
pub var dbg_hh_n: usize = 0;
pub fn dbgHhEnable(func: u16) void { dbg_hh_watch = true; dbg_hh_func = func; dbg_hh_n = 0; }
pub fn dbgHhN() usize { return dbg_hh_n; }
pub fn dbgHhCallee(i: usize) u16 { return if (i < dbg_hh_n) dbg_hh_callee[i] else 0xFFFF; }
pub fn dbgHhIp(i: usize) u32 { return if (i < dbg_hh_n) dbg_hh_ip[i] else 0; }
pub var dbg_vp_watch: bool = false;
pub var dbg_vp_bi_arr: [512]f64 = [_]f64{-999999} ** 512;
pub var dbg_vp_flags_arr: [512]u32 = [_]u32{0} ** 512;
pub var dbg_vp_n: usize = 0;
pub var dbg_vp_func: u16 = 0xFFFF;
pub fn dbgVpFunc() u16 { return dbg_vp_func; }
pub var dbg_vp_ret_arr: [512]u8 = [_]u8{9} ** 512;
pub var dbg_vp_ret_n: usize = 0;
pub var dbg_vp_pending: bool = false;
pub fn dbgVpRetN() usize { return dbg_vp_ret_n; }
pub fn dbgVpRetAt(i: usize) u8 { return if (i < dbg_vp_n) dbg_vp_ret_arr[i] else 9; }
pub fn dbgVpEnable() void { dbg_vp_watch = true; dbg_vp_n = 0; dbg_vp_func = 0xFFFF; dbg_vp_ret_n = 0; }
pub fn dbgVpN() usize { return dbg_vp_n; }
pub fn dbgVpBiAt(i: usize) f64 { return if (i < dbg_vp_n) dbg_vp_bi_arr[i] else -999999; }
pub fn dbgVpFlagsAt(i: usize) u32 { return if (i < dbg_vp_n) dbg_vp_flags_arr[i] else 0; }
// Per-call O tracking: total calls, u histogram, and the last return value tag.
pub var dbg_ocall_total: u64 = 0;
pub var dbg_ocall_u: [128]f64 = [_]f64{-1} ** 128; // distinct u values seen
pub var dbg_ocall_ucount: [128]u64 = [_]u64{0} ** 128;
pub var dbg_ocall_un: usize = 0;
pub fn dbgOCallTotal() u64 { return dbg_ocall_total; }
pub fn dbgOCallUn() usize { return dbg_ocall_un; }
pub fn dbgOCallU(i: usize) f64 { return if (i < dbg_ocall_un) dbg_ocall_u[i] else -1; }
pub fn dbgOCallUCount(i: usize) u64 { return if (i < dbg_ocall_un) dbg_ocall_ucount[i] else 0; }
fn recordOCall(u_val: f64) void {
    dbg_ocall_total += 1;
    var i: usize = 0;
    while (i < dbg_ocall_un) : (i += 1) {
        if (dbg_ocall_u[i] == u_val) { dbg_ocall_ucount[i] += 1; return; }
    }
    if (dbg_ocall_un < dbg_ocall_u.len) {
        dbg_ocall_u[dbg_ocall_un] = u_val;
        dbg_ocall_ucount[dbg_ocall_un] = 1;
        dbg_ocall_un += 1;
    }
}

// Last get_elem seen (object + key), so a callee produced by get_elem can be
// traced to the exact T-bank index it was read from.
pub var dbg_lastgetelem_objidx: u32 = 0xFFFFFFFF;
pub var dbg_lastgetelem_keynum: f64 = 0;
pub var dbg_lastgetelem_keytag: u8 = 255;
pub var dbg_lastgetelem_keystr: [48]u8 = [_]u8{0} ** 48;
pub var dbg_lastgetelem_keystr_len: usize = 0;
pub var dbg_lastgetelem_result_functag: bool = false;
pub var dbg_emptyge_captured: bool = false;
pub var dbg_emptyge_keytag: u8 = 255;
pub var dbg_emptyge_keynum: f64 = 0;
pub var dbg_emptyge_func: u16 = 0xFFFF;
pub var dbg_emptyge_ip: u32 = 0;
pub var dbg_emptyge_gf_tag: u8 = 255;
pub var dbg_emptyge_gf_obj: u32 = 0xFFFFFFFF;
pub var dbg_emptyge_gf_hasv: u8 = 255;
pub var dbg_emptyge_fframes: u32 = 0;
pub var dbg_emptyge_nearest_ffunc: u16 = 0xFFFF;
pub var dbg_emptyge_framelist: [64]u16 = [_]u16{0xFFFF} ** 64;
pub var dbg_emptyge_framelist_n: usize = 0;
pub fn dbgEmptygeFrame(i: usize) u16 { return dbg_emptyge_framelist[i % 64]; }

pub var dbg_ctor_calls: u32 = 0;
pub var dbg_ctor_funcs: [16]u16 = [_]u16{0xFFFF} ** 16;
pub var dbg_ctor_n: usize = 0;
pub var dbg_v113_total: u32 = 0;
pub var dbg_v113_reg394: u32 = 0;
pub var dbg_v113_first_x: f64 = -1;
pub var dbg_op95_first_v113: u32 = 0;
pub fn dbgV113Total() u32 { return dbg_v113_total; }
pub fn dbgV113Reg394() u32 { return dbg_v113_reg394; }
pub fn dbgV113FirstX() f64 { return dbg_v113_first_x; }
pub fn dbgOp95FirstV113() u32 { return dbg_op95_first_v113; }
// ── Full register-read logger (Q + v readers) for cross-engine value bisection.
pub const dbg_qr_cap: usize = 20000;
pub var dbg_qr_qid: u16 = 0xFFFF;
pub var dbg_qr_vid: u16 = 0xFFFF;
pub var dbg_qr_eid: u16 = 0xFFFF;
pub var dbg_qr_n: usize = 0;
pub var dbg_qr_reg: [dbg_qr_cap]u32 = undefined;
pub var dbg_qr_isobj: [dbg_qr_cap]u8 = undefined;
pub var dbg_qr_val: [dbg_qr_cap]f64 = undefined;
pub var dbg_qr_e: [dbg_qr_cap][3]f64 = undefined;
pub fn dbgQrSet(qid: u16, vid: u16) void { dbg_qr_qid = qid; dbg_qr_vid = vid; dbg_qr_n = 0; }
pub fn dbgQrSetE(eid: u16) void { dbg_qr_eid = eid; }
pub fn dbgQrN() usize { return dbg_qr_n; }
pub fn dbgQrReg(i: usize) u32 { return if (i < dbg_qr_n) dbg_qr_reg[i] else 0xFFFFFFFF; }
pub fn dbgQrIsObj(i: usize) u8 { return if (i < dbg_qr_n) dbg_qr_isobj[i] else 255; }
pub fn dbgQrVal(i: usize) f64 { return if (i < dbg_qr_n) dbg_qr_val[i] else -987654.0; }
pub fn dbgQrE(i: usize, j: usize) f64 { return if (i < dbg_qr_n and j < 3) dbg_qr_e[i][j] else -987654.0; }
// ── Decoder-construction trace (ch=86, M6=125, Hh=88). Set the ids from the
// create_test findfn scan via dbgDecSetIds; counts/tags captured at entry/exit.
pub var dbg_dec_ch_id: u16 = 0xFFFF;
pub var dbg_dec_m6_id: u16 = 0xFFFF;
pub var dbg_dec_hh_id: u16 = 0xFFFF;
pub var dbg_dec_op95_id: u16 = 0xFFFF;
pub var dbg_dec_op95_entries: u32 = 0;
pub fn dbgDecOp95SetId(id: u16) void { dbg_dec_op95_id = id; }
pub fn dbgDecOp95Entries() u32 { return dbg_dec_op95_entries; }
// ── mS keystream-input capture: when mS (dbg_ms_id) runs with block g(param3)==dbg_ms_target_block, capture x(B),g(O),L[2](Z1),L[3](Z2).
pub var dbg_ms_id: u16 = 0xFFFF;
pub var dbg_ms_target_block: f64 = 517.0;
pub var dbg_ms_done: bool = false;
pub var dbg_ms_x: f64 = -1; // B (key)
pub var dbg_ms_g: f64 = -1; // O (block)
pub var dbg_ms_L2: f64 = -987654.0; // Z[1]
pub var dbg_ms_L3: f64 = -987654.0; // Z[2]
pub var dbg_ms_L_tag: u8 = 255;
pub fn dbgMsSetId(id: u16) void { dbg_ms_id = id; }
pub fn dbgMsSetTargetBlock(b: f64) void { dbg_ms_target_block = b; }
pub fn dbgMsX() f64 { return dbg_ms_x; }
pub fn dbgMsG() f64 { return dbg_ms_g; }
pub fn dbgMsL2() f64 { return dbg_ms_L2; }
pub fn dbgMsL3() f64 { return dbg_ms_L3; }
pub fn dbgMsLTag() u8 { return dbg_ms_L_tag; }
// ── wU(363,x,g) write capture: record each write to register 363 (its g-array
// first 3 elems + the writing inner-VM caller func). b=param1, g=param3.
pub var dbg_wu_id: u16 = 0xFFFF;
pub var dbg_wu363_n: u32 = 0;
pub var dbg_wu363_e0: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_wu363_e1: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_wu363_e2: [64]f64 = [_]f64{-987654.0} ** 64;
pub var dbg_wu363_gtag: [64]u8 = [_]u8{255} ** 64;
pub var dbg_wu363_caller: [64]u16 = [_]u16{0xFFFF} ** 64;
pub fn dbgWuSetId(id: u16) void { dbg_wu_id = id; }
pub fn dbgWu363N() u32 { return dbg_wu363_n; }
pub fn dbgWu363E0(i: usize) f64 { return if (i < 64) dbg_wu363_e0[i] else -987654.0; }
pub fn dbgWu363E1(i: usize) f64 { return if (i < 64) dbg_wu363_e1[i] else -987654.0; }
pub fn dbgWu363E2(i: usize) f64 { return if (i < 64) dbg_wu363_e2[i] else -987654.0; }
pub fn dbgWu363GTag(i: usize) u8 { return if (i < 64) dbg_wu363_gtag[i] else 255; }
pub fn dbgWu363Caller(i: usize) u16 { return if (i < 64) dbg_wu363_caller[i] else 0xFFFF; }
pub var dbg_dec_ch_entries: u32 = 0;    // # times ch body entered
pub var dbg_dec_ch_ret_tag: u8 = 255;   // ch's return value tag (first)
pub var dbg_dec_ch_ret_obj: u32 = 0xFFFFFFFF;
pub var dbg_dec_m6_entries: u32 = 0;    // # times M6 entered
pub var dbg_dec_m6_rets: u32 = 0;       // # times M6 returned normally (ret)
pub var dbg_dec_m6_w_tag: u8 = 255;     // M6's W param (slot 7) tag on first entry
pub var dbg_dec_m6_w_obj: u32 = 0xFFFFFFFF;
pub var dbg_dec_hh_entries: u32 = 0;    // # times Hh entered
pub var dbg_dec_hh_g_tag: u8 = 255;     // Hh's g param (slot 3) tag on first entry
pub var dbg_dec_hh_g_obj: u32 = 0xFFFFFFFF;
pub var dbg_dec_newch_restag: u8 = 255; // tag of `new ch` RESULT (callConstructor path)
pub var dbg_dec_newch_resobj: u32 = 0xFFFFFFFF;
pub var dbg_dec_newch_seen: u32 = 0;    // # of `new ch` (func==ch_id) constructions
pub fn dbgDecSetIds(ch: u16, m6: u16, hh: u16) void { dbg_dec_ch_id = ch; dbg_dec_m6_id = m6; dbg_dec_hh_id = hh; }
pub fn dbgDecChEntries() u32 { return dbg_dec_ch_entries; }
pub fn dbgDecChRetTag() u8 { return dbg_dec_ch_ret_tag; }
pub fn dbgDecChRetObj() u32 { return dbg_dec_ch_ret_obj; }
pub fn dbgDecM6Entries() u32 { return dbg_dec_m6_entries; }
pub fn dbgDecM6Rets() u32 { return dbg_dec_m6_rets; }
pub fn dbgDecM6WTag() u8 { return dbg_dec_m6_w_tag; }
pub fn dbgDecM6WObj() u32 { return dbg_dec_m6_w_obj; }
pub fn dbgDecHhEntries() u32 { return dbg_dec_hh_entries; }
pub fn dbgDecHhGTag() u8 { return dbg_dec_hh_g_tag; }
pub fn dbgDecHhGObj() u32 { return dbg_dec_hh_g_obj; }
pub fn dbgDecNewChRestag() u8 { return dbg_dec_newch_restag; }
pub fn dbgDecNewChResObj() u32 { return dbg_dec_newch_resobj; }
pub fn dbgDecNewChSeen() u32 { return dbg_dec_newch_seen; }
// ── FH entry trace (func 96): all 6 params + caller on first entry.
pub var dbg_fhentry_done: bool = false;
pub var dbg_fhentry_argc: u8 = 0;
pub var dbg_fhentry_caller: u16 = 0xFFFF;
pub var dbg_fhentry_caller_ip: u32 = 0xFFFFFFFF;
pub var dbg_fhentry_tags: [7]u8 = [_]u8{255} ** 7;
pub var dbg_fhentry_nums: [7]f64 = [_]f64{-987654.0} ** 7;
pub var dbg_fhentry_objs: [7]u32 = [_]u32{0xFFFFFFFF} ** 7;
pub fn dbgFhEntryArgc() u8 { return dbg_fhentry_argc; }
pub fn dbgFhEntryCaller() u16 { return dbg_fhentry_caller; }
pub fn dbgFhEntryCallerIp() u32 { return dbg_fhentry_caller_ip; }
pub fn dbgFhEntryTag(i: usize) u8 { return if (i < 7) dbg_fhentry_tags[i] else 255; }
pub fn dbgFhEntryNum(i: usize) f64 { return if (i < 7) dbg_fhentry_nums[i] else -987654.0; }
pub fn dbgFhEntryObj(i: usize) u32 { return if (i < 7) dbg_fhentry_objs[i] else 0xFFFFFFFF; }
pub fn dbgCtorCalls() u32 { return dbg_ctor_calls; }
pub fn dbgCtorN() usize { return dbg_ctor_n; }
pub fn dbgCtorFunc(i: usize) u16 { return if (i < 16) dbg_ctor_funcs[i] else 0xFFFF; }
fn callConstructor(argc: u8) void {
    // new F(args): create an object, call F with it bound as `this`.
    if (sp < argc + 1) { fail("new: stack underflow"); return; }

    const ctor_slot = sp - 1 - argc;
    const native_ctor = stack[ctor_slot];
    if (native_ctor.tag == .function) {
        const id = objects.closureFuncId(native_ctor.data.func_idx);
        const native_without_constructor = id >= builtins.NATIVE_BASE and !builtins.nativeHasPrototype(id) and id != builtins.N_PROXY_CONSTRUCTOR and !objects.hasOwnProperty(native_ctor.data.func_idx, values.internString("prototype"));
        if (id == builtins.N_FUNCTION_PROTO or id == builtins.N_SYMBOL or native_without_constructor or (id < builtins.NATIVE_BASE and (compiler.getFunction(id).is_arrow or compiler.getFunction(id).is_async or compiler.getFunction(id).is_generator))) { throwTypeErrorMsg("function is not a constructor"); return; }
    }
    if (native_ctor.tag == .function and objects.closureFuncId(native_ctor.data.func_idx) == builtins.N_NUMBER_CTOR) {
        const result = builtins.constructNumber(stack[ctor_slot + 1 .. sp]);
        if (operation_aborted) return;
        sp = ctor_slot;
        if (checkNativeThrow()) return;
        push(result);
        return;
    }
    if (native_ctor.tag == .function and objects.closureFuncId(native_ctor.data.func_idx) == builtins.N_BOOLEAN_CTOR) {
        const result = builtins.constructBoolean(stack[ctor_slot + 1 .. sp]);
        sp = ctor_slot;
        push(result);
        return;
    }
    if (native_ctor.tag == .function and objects.closureFuncId(native_ctor.data.func_idx) == builtins.N_STRING_CTOR) {
        const result = builtins.constructString(stack[ctor_slot + 1 .. sp]);
        sp = ctor_slot;
        if (checkNativeThrow()) return;
        push(result);
        return;
    }
    if (native_ctor.tag == .function and objects.closureFuncId(native_ctor.data.func_idx) == builtins.N_DATE_CTOR) {
        const result = builtins.constructDate(stack[ctor_slot + 1 .. sp]);
        sp = ctor_slot;
        push(result);
        return;
    }

    const new_obj = objects.createObject();
    const depth_before = frame_count;
    // DIAGNOSTIC: count `new X()` calls + record the first 16 constructor func ids.
    dbg_ctor_calls += 1;
    { const cpk = if (sp >= argc + 1) stack[sp - 1 - argc] else Value.UNDEFINED;
      if (dbg_ctor_n < dbg_ctor_funcs.len) {
          dbg_ctor_funcs[dbg_ctor_n] = if (cpk.tag == .function) objects.closureFuncId(cpk.data.func_idx) else 0xFFFE;
          dbg_ctor_n += 1; }
      // Count `new ch` specifically.
      if (cpk.tag == .function and objects.closureFuncId(cpk.data.func_idx) == dbg_dec_ch_id) dbg_dec_newch_seen += 1; }

    // Link the new object's [[Prototype]] to F.prototype so that
    // `newObj instanceof F` and prototype-method lookups work. The callee F is
    // at stack[sp-1-argc]. Accessing `.prototype` lazily creates it.
    const callee_peek = if (sp >= argc + 1) stack[sp - 1 - argc] else Value.UNDEFINED;
    if (callee_peek.tag == .function) {
        const fproto = getPropFromValue(callee_peek, values.internString("prototype"));
        if (fproto.tag == .object or fproto.tag == .array or fproto.tag == .function) {
            objects.setObjectPrototype(new_obj, @intCast(fproto.data.obj_idx));
        }
    }

    // Dispatch the call normally (the callee function must stay in place so
    // callFunction can find it). callFunction sets bp = the callee slot.
    const caller = SyncCaller.capture();
    callFunction(argc);
    if (frame_count <= depth_before and caller.transferred()) return;

    if (frame_count > depth_before) {
        // A user-function frame was pushed: overwrite its slot 0 (this) with
        // the new object. Remember this frame so its return yields new_obj when
        // the constructor returns undefined/non-object.
        const bp = frames[frame_count - 1].bp;
        if (bp < MAX_STACK) stack[bp] = Value.object(new_obj);
        const fi = frame_count - 1;
        if (fi < MAX_FRAMES) { ctor_new_obj[fi] = new_obj; ctor_is[fi] = true; }
    } else {
        // Native/immediate: if it didn't return an object, use the new object.
        if (sp > 0 and stack[sp - 1].tag != .object and stack[sp - 1].tag != .array and stack[sp-1].tag != .function) {
            stack[sp - 1] = Value.object(new_obj);
        }
    }
}

/// Close any open upvalues that reference stack slots at or above `min_addr`
/// (i.e. locals of a frame that is about to be discarded). The captured
/// variable's current value is snapshotted into the closure so it survives
/// after the frame's stack slots are reused.
fn closeUpvalues(min_addr: u32) void {
    // Iterate only the compact OPEN-cell list. Close cells whose live stack
    // address belongs to the frame being discarded (addr >= min_addr),
    // snapshotting their current value; then compact the open list.
    const open_n = objects.openCellCount();
    var k: u32 = 0;
    while (k < open_n) : (k += 1) {
        const ci = objects.openCellAt(k);
        if (ci == objects.NO_CELL) continue;
        const addr = objects.cellAddr(ci);
        if (addr != objects.NO_UPVAL_ADDR and addr >= min_addr and addr < MAX_STACK) {
            if (dbg_watch_addr != 0xFFFFFFFF and addr == dbg_watch_addr) dbg_close143 += 1;
            if (dbg_closetrace and dbg_closetrace_n < 8) {
                dbg_closetrace_addr[dbg_closetrace_n] = ci;
                dbg_closetrace_min[dbg_closetrace_n] = min_addr;
                dbg_closetrace_valtag[dbg_closetrace_n] = @intFromEnum(stack[addr].tag);
                dbg_closetrace_n += 1;
            }
            // Debug: catch the first time we snapshot a stack slot holding an
            // INVALID Value tag (>8) — i.e. uninitialized/garbage memory being
            // closed into an upvalue cell (the tag=255 seen in ncm diagnostics).
            const sv = stack[addr];
            if (!dbg_badclose_captured and @intFromEnum(sv.tag) > 8) {
                dbg_badclose_captured = true;
                dbg_badclose_addr = addr;
                dbg_badclose_min = min_addr;
                dbg_badclose_sp = @intCast(sp);
                dbg_badclose_cell = ci;
                dbg_badclose_tag = @intFromEnum(sv.tag);
                if (frame_count > 0) { dbg_badclose_func = frames[frame_count - 1].func_id; dbg_badclose_bp = frames[frame_count - 1].bp; }
            }
            objects.closeCell(ci, stack[addr]);
        }
    }
    objects.compactOpenCells();
}
// ── Loop-hotspot histogram (populated only in the last ~1M steps before the
// nested step limit, so it costs nothing on the fast path). Records the top
// executing (func,ip) sites so the failure diagnostic pinpoints the spinning
// bytecode. Small fixed table with linear probe.
const HOT_SLOTS: usize = 32;
var dbg_hot_func: [HOT_SLOTS]u16 = [_]u16{0xFFFF} ** HOT_SLOTS;
var dbg_hot_ip: [HOT_SLOTS]u32 = [_]u32{0xFFFFFFFF} ** HOT_SLOTS;
var dbg_hot_cnt: [HOT_SLOTS]u32 = [_]u32{0} ** HOT_SLOTS;
var dbg_hot_fc_min: u32 = 0xFFFFFFFF;
var dbg_hot_fc_max: u32 = 0;
fn dbgHotRecord(func_id: u16, ip: u32, fc: u32) void {
    if (fc < dbg_hot_fc_min) dbg_hot_fc_min = fc;
    if (fc > dbg_hot_fc_max) dbg_hot_fc_max = fc;
    var i: usize = 0;
    while (i < HOT_SLOTS) : (i += 1) {
        if (dbg_hot_func[i] == func_id and dbg_hot_ip[i] == ip) { dbg_hot_cnt[i] += 1; return; }
        if (dbg_hot_cnt[i] == 0) { dbg_hot_func[i] = func_id; dbg_hot_ip[i] = ip; dbg_hot_cnt[i] = 1; return; }
    }
    // Table full: bump a fallback aggregate so we still know it overflowed.
    dbg_hot_overflow += 1;
}
pub var dbg_hot_overflow: u32 = 0;
pub fn dbgHotCount() usize { return HOT_SLOTS; }
pub fn dbgHotFunc(i: usize) u16 { return dbg_hot_func[i]; }
pub fn dbgHotIp(i: usize) u32 { return dbg_hot_ip[i]; }
pub fn dbgHotHits(i: usize) u32 { return dbg_hot_cnt[i]; }
pub fn dbgHotFcMin() u32 { return dbg_hot_fc_min; }
pub fn dbgHotFcMax() u32 { return dbg_hot_fc_max; }
pub var dbg_badclose_captured: bool = false;
pub var dbg_badclose_addr: u32 = 0;
pub var dbg_badclose_min: u32 = 0;
pub var dbg_badclose_sp: u32 = 0;
pub var dbg_badclose_cell: u32 = 0;
pub var dbg_badclose_tag: u8 = 0;
pub var dbg_badclose_func: u16 = 0xFFFF;
pub var dbg_badclose_bp: u32 = 0;
pub var dbg_close143: u32 = 0;
pub fn dbgClose143() u32 { return dbg_close143; }
var dbg_wcorrupt_detected: bool = false;
var dbg_wcorrupt_anc_func: u16 = 0;
var dbg_wcorrupt_anc_bp: u16 = 0;
var dbg_wcorrupt_anc_lc: u16 = 0;
var dbg_wcorrupt_anc_depth: u16 = 0;
var dbg_wcorrupt_writer_depth: u16 = 0;
pub fn dbgWCorrupt() [6]u32 { return .{ if (dbg_wcorrupt_detected) 1 else 0, dbg_wcorrupt_anc_func, dbg_wcorrupt_anc_bp, dbg_wcorrupt_anc_lc, dbg_wcorrupt_anc_depth, dbg_wcorrupt_writer_depth }; }
pub var dbg_slotwatch_func: u16 = 0xFFFF;
var dbg_slotwatch_137_writes: u32 = 0;
var dbg_slotwatch_maxslot: u16 = 0;
var dbg_slotwatch_137_tag: u8 = 255;
var dbg_slotwatch_137_bp: u16 = 0;
var dbg_slotwatch_137_ip: u32 = 0;
var dbg_s137_l0: u32 = 0;
var dbg_s137_l1: u32 = 0;
var dbg_s137_l2: u32 = 0;
pub fn dbgSlotwatch137() u32 { return dbg_slotwatch_137_writes; }
pub fn dbgSlotwatchMax() u16 { return dbg_slotwatch_maxslot; }
pub fn dbgSlotwatch137Tag() u8 { return dbg_slotwatch_137_tag; }
pub fn dbgSlotwatch137Bp() u16 { return dbg_slotwatch_137_bp; }
pub fn dbgSlotwatch137Ip() u32 { return dbg_slotwatch_137_ip; }
pub fn dbgS137L(i: usize) []const u8 {
    const v = switch (i) { 0 => dbg_s137_l0, 1 => dbg_s137_l1, else => dbg_s137_l2 };
    return if (v == 0) "" else values.getString(v);
}
var dbg_s137_op: [80]u8 = [_]u8{0} ** 80;
var dbg_s137_op_n: usize = 0;
pub fn dbgS137OpCount() usize { return dbg_s137_op_n; }
pub fn dbgS137OpName(i: usize) []const u8 { if (i >= dbg_s137_op_n) return ""; return @tagName(@as(Op, @enumFromInt(dbg_s137_op[i]))); }

fn returnFromFrame(result_in: Value) void {
    if (frame_count > 0 and returnThroughFinally(result_in)) return;
    if (debug_function_return) |observe| {
        if (frame_count > 0) {
            const current = frames[frame_count - 1];
            const desc = compiler.getFunction(current.func_id);
            observe(current.func_id, stack[current.bp..@min(sp, current.bp + @as(u32, desc.param_count) + 1)], result_in);
        }
    }
    if (dbg_gtrace_on and dbg_gtrace_n == 16350 and frame_count > 0 and dbg_ud_n < dbg_ud_result.len) {
        const frame = frames[frame_count-1];
        if (startsWith(compiler.funcSourceText(frame.func_id), "function(J,z,Z,b,k,c,l,D,T,H,P,G,v,q,p,g){for(p=47;")) {
            const state = stack[frame.bp+6];
            dbg_ud_result[dbg_ud_n] = result_in;
            for (0..16) |i| dbg_ud_slots[dbg_ud_n][i] = stack[frame.bp+i];
            if (state.tag == .object) {
                for ([_][]const u8{"G","Pv","eS","ED","nW","T","Tb","Vm","S0","l","O","N","W9","I","B9","K"},0..) |name,i| dbg_ud_fields[dbg_ud_n][i] = objects.getProperty(state.data.obj_idx, values.internString(name));
            }
            dbg_ud_n += 1;
        }
    }
    if (dbg_gtrace_on and frame_count > 0 and dbg_factory_n < dbg_factory_rows.len) {
        const frame = frames[frame_count-1];
        if (startsWith(compiler.funcSourceText(frame.func_id), "function(G,v,q){if((H=(q=(v=")) {
            const reg = debugUpvalue(frame, "J");
            if (reg.tag == .number and reg.data.number == @as(f64, @floatFromInt(dbg_factory_register))) {
                dbg_factory_rows[dbg_factory_n] = .{ result_in, stack[frame.bp+1], stack[frame.bp+2], stack[frame.bp+3], debugUpvalue(frame,"D"), debugUpvalue(frame,"H"), debugUpvalue(frame,"c"), debugUpvalue(frame,"z"), debugUpvalue(frame,"k") };
                dbg_factory_n += 1;
            }
        }
    }
    var result = result_in;
    if (dbg_gtrace_on and frame_count > 0) {
        const hf = frames[frame_count - 1];
        const hs = compiler.funcSourceText(hf.func_id);
        if (startsWith(hs, "function(b,x,g){return(g=x.create().shift(),")) {
            dbgHkRecord(2, stack[hf.bp + 1], result_in);
        } else if (startsWith(hs, "function(b,x,g,Y,L,F,W,D,t,r,d,h){") and stack[hf.bp + 1].tag == .number and stack[hf.bp + 1].data.number == 8) {
            dbgHkRecord(1, stack[hf.bp + 2], result_in);
        }
    }
    if (frame_count > 0 and eql(compiler.funcSourceText(frames[frame_count-1].func_id), "function(){return x==b?-5:-51}")) dbg_ai_ret = result_in;
    // Debug: log the RETURN value of the jlog func (register-read J) for its
    // first calls, so we can compare the resolved register (opcode) values with
    // the reference. result_in is J's return (the register value).
    // Q363 return: log the Nth Q(363) result value (drives the dispatch branch
    // that diverges right after the 288th Q363 read).
    if (dbg_q363_on and dbg_q363_pending and frame_count > 0 and frames[frame_count - 1].func_id == 182) {
        dbg_q363_pending = false;
        if (dbg_q363_n < dbg_q363_max) {
            dbg_q363_val[dbg_q363_n] = if (result_in.tag == .number) result_in.data.number else -1234567890123.0;
            dbg_q363_tag[dbg_q363_n] = @intFromEnum(result_in.tag);
            // Capture the returned object's first 4 array elements (Q363 = g.prototype
            // = this.concat() = an array of numbers; the dispatcher branches on them).
            if ((result_in.tag == .object or result_in.tag == .array) and dbg_q363_n < dbg_q363_elems.len) {
                const roi = result_in.data.obj_idx;
                dbg_q363_obj[dbg_q363_n] = roi;
                var ei: usize = 0;
                while (ei < 4) : (ei += 1) {
                    const ev = objects.getArrayElement(roi, @intCast(ei));
                    dbg_q363_elems[dbg_q363_n][ei] = if (ev.tag == .number) ev.data.number else -1234567890123.0;
                }
            }
            dbg_q363_n += 1;
        }
    }
    // Trace the vP function's return value per call (to find where ours returns
    // true (do-eval) but jsdom returns false (skip-eval)).
    if (dbg_vp_watch and dbg_vp_pending and dbg_vp_func != 0xFFFF and frame_count > 0 and frames[frame_count - 1].func_id == dbg_vp_func and dbg_vp_n >= 1 and dbg_vp_n - 1 < dbg_vp_ret_arr.len) {
        dbg_vp_pending = false;
        dbg_vp_ret_arr[dbg_vp_n - 1] = if (result_in.tag == .boolean) @intCast(result_in.data.boolean) else (if (result_in.tag == .undefined) 2 else 3);
    }
    // Trace the G reader (func dbg_gtrace_func) return values, so the decoded
    // operand array (dL = g[1][1]) element sequence can be diffed vs the oracle.
    if (dbg_gtrace_on and frame_count > 0 and (frames[frame_count - 1].func_id == dbg_gtrace_func or (if (dbg_gtrace_prefix) |prefix| startsWith(compiler.funcSourceText(frames[frame_count - 1].func_id), prefix) else false) or startsWith(compiler.funcSourceText(frames[frame_count - 1].func_id), "function(b,x,g,Y,L){for(null==false;") or startsWith(compiler.funcSourceText(frames[frame_count - 1].func_id), "function(f,Q,E,T,D,e,H,q,P,O,I,Y,K,V,y,X){if((V=b(f,94),V)>=")) and dbg_gtrace_n < dbg_gtrace_val.len) {
        if (dbg_gtrace_n == 16349 and frame_count >= 3) {
            const state = stack[frames[frame_count-1].bp+2];
            const saved = stack[frames[frame_count-3].bp+4];
            const current = objects.getProperty(state.data.obj_idx, values.internString("R"));
            for ([_]Value{ saved, current },0..) |array,i| {
                const cell = objects.getArrayElement(array.data.obj_idx,57);
                dbg_snapshot_cells[i+2] = cell;
                const getter = objects.getProperty(cell.data.obj_idx,values.internString("create"));
                dbg_snapshot_cells[i] = if (getter.tag == .function) debugUpvalue(.{ .func_id=objects.closureFuncId(getter.data.func_idx),.closure_obj=getter.data.func_idx },"J") else Value.UNDEFINED;
            }
        }
        dbg_gtrace_val[dbg_gtrace_n] = if (result_in.tag == .number) result_in.data.number else -1234567890123.0;
        // Record G's selector arg x (local 2) so we can see if a divergent read
        // used a varint-triggering selector.
        const gf = frames[frame_count - 1];
        const gsrc = compiler.funcSourceText(gf.func_id);
        dbg_gtrace_pos[dbg_gtrace_n] = if ((dbg_gtrace_prefix != null or startsWith(gsrc, "function(f,Q,E,T,D,e,H,q,P,O,I,Y,K,V,y,X){if((V=b(f,94),V)>=")) and gf.bp + dbg_gtrace_pos_slot < MAX_STACK and stack[gf.bp + dbg_gtrace_pos_slot].tag == .number) stack[gf.bp + dbg_gtrace_pos_slot].data.number else -1;
        dbg_gtrace_sel[dbg_gtrace_n] = if (gf.bp + dbg_gtrace_sel_slot < MAX_STACK and stack[gf.bp + dbg_gtrace_sel_slot].tag == .number) @intFromFloat(stack[gf.bp + dbg_gtrace_sel_slot].data.number) else -1;
        // At the known-divergent G index, capture the full caller stack (func@ip)
        // so we can identify the dispatch that chose the wrong selector.
        if (dbg_gtrace_n == dbg_gtrace_cap_idx) {
            const state = stack[gf.bp + 1];
            if (startsWith(gsrc, "function(f,Q,E,T,D,e,H,q,P,O,I,Y,K,V,y,X){if((V=b(f,94),V)>=") and (state.tag == .object or state.tag == .array)) {
                for ([_][]const u8{ "A", "O", "KJ", "oP", "e" }, 0..) |name, ki| {
                    const kv = if (ki == 4) stack[gf.bp + 6] else objects.getProperty(state.data.obj_idx, values.internString(name));
                    dbg_gtrace_cap_keyvals[ki] = kv;
                    const kl = if (kv.tag == .object or kv.tag == .array) objects.arrayLength(kv.data.obj_idx) else 0;
                    dbg_gtrace_cap_keylens[ki] = kl;
                    for (0..@min(kl, 32)) |kj| dbg_gtrace_cap_keynums[ki][kj] = objects.getArrayElement(kv.data.obj_idx, @intCast(kj));
                }
            }
            dbg_gtrace_cap_n = 0;
            var gsi: usize = frame_count;
            while (gsi > 0 and dbg_gtrace_cap_n < dbg_gtrace_cap_func.len) { gsi -= 1;
                dbg_gtrace_cap_func[dbg_gtrace_cap_n] = frames[gsi].func_id;
                dbg_gtrace_cap_ip[dbg_gtrace_cap_n] = frames[gsi].ip;
                for (0..16) |j| dbg_gtrace_cap_slots[dbg_gtrace_cap_n][j] = if (frames[gsi].bp+j < MAX_STACK) stack[frames[gsi].bp+j] else Value.UNDEFINED;
                dbg_gtrace_cap_n += 1;
            }
        }
        dbg_gtrace_n += 1;
    }
    // Capture the RETURN VALUE of a Q-read (func dbg_rt_qfunc) into the pending
    // register-trace entry, so the register-VALUE sequence can be diffed vs the
    // oracle to find the first register whose returned value diverges (the root).
    if (dbg_rt_on and dbg_rt_qret_pending and frame_count > 0 and frames[frame_count - 1].func_id == dbg_rt_qfunc) {
        dbg_rt_qret_pending = false;
        if (dbg_rt_qret_idx < dbg_rt_n) {
            dbg_rt_val[dbg_rt_qret_idx] = if (result_in.tag == .number) result_in.data.number else -1234567890123.0;
            // For object/array returns, fold the first 2 array elements into the
            // trace as a fingerprint (numbers only) via dbg_rt_e0/e1 arrays.
            if (result_in.tag == .object or result_in.tag == .array) {
                const roi2 = result_in.data.obj_idx;
                const e0 = objects.getArrayElement(roi2, 0);
                const e1 = objects.getArrayElement(roi2, 1);
                dbg_rt_e0[dbg_rt_qret_idx] = if (e0.tag == .number) e0.data.number else -1234567890123.0;
                dbg_rt_e1[dbg_rt_qret_idx] = if (e1.tag == .number) e1.data.number else -1234567890123.0;
            }
        }
    }
    if (frame_count > 0 and frames[frame_count - 1].func_id == dbg_jlog_func and dbg_jret_n < 40) {
        dbg_jret_tag[dbg_jret_n] = @intFromEnum(result_in.tag);
        dbg_jret_num[dbg_jret_n] = if (result_in.tag == .number) result_in.data.number else -1;
        dbg_jret_n += 1;
    }
    // PP-result trace: log the return value of the PP bit-reader (dbg_pp_func)
    // as a uint32, so the decoded-bits sequence can be diffed against the oracle.
    if (dbg_pp_on and frame_count > 0 and frames[frame_count - 1].func_id == dbg_pp_func and dbg_pp_n < dbg_pp_max) {
        const rv: f64 = if (result_in.tag == .number) result_in.data.number else -1;
        dbg_pp_ret[dbg_pp_n] = rv;
        // Record p (slot15) and g (slot3) per call for tuple diffing.
        const fr0 = frames[frame_count - 1];
        dbg_pp_p_arr[dbg_pp_n] = if (fr0.bp + 15 < MAX_STACK and stack[fr0.bp + 15].tag == .number) stack[fr0.bp + 15].data.number else -1;
        dbg_pp_g_arr[dbg_pp_n] = if (fr0.bp + 3 < MAX_STACK and stack[fr0.bp + 3].tag == .number) stack[fr0.bp + 3].data.number else -1;
        // Record the immediate CALLER func id of PP (the G/sT reader) per call, so
        // the reader-selection (G varint vs sT plain) sequence can be diffed vs
        // the oracle to find the varint-framing offset root.
        dbg_pp_caller_arr[dbg_pp_n] = if (frame_count >= 2) frames[frame_count - 2].func_id else 0xFFFF;
        // Capture the FIRST PP call at bit-position 26644 (the deterministic
        // divergence point) — position-keyed so it aligns with the oracle.
        const fr_p: f64 = if (frames[frame_count - 1].bp + 15 < MAX_STACK and stack[frames[frame_count - 1].bp + 15].tag == .number) stack[frames[frame_count - 1].bp + 15].data.number else -1;
        if (fr_p == @as(f64, @floatFromInt(dbg_pp_cap_pos)) and !dbg_pp_cap_done) {
            dbg_pp_cap_done = true;
            const fr = frames[frame_count - 1];
            // p = PP's local slot 15 (set right after Q(184,x)); g = slot 3 (not
            // mutated after g→L); b = slot 1. Read at RETURN (same call as the
            // logged result, avoiding entry/return counter desync).
            dbg_pp_cap_p_actual = if (fr.bp + 15 < MAX_STACK and stack[fr.bp + 15].tag == .number) stack[fr.bp + 15].data.number else -1;
            dbg_pp_cap_g_actual = if (fr.bp + 3 < MAX_STACK and stack[fr.bp + 3].tag == .number) stack[fr.bp + 3].data.number else -1;
            dbg_pp_cap_b_actual = if (fr.bp + 1 < MAX_STACK) @intFromEnum(stack[fr.bp + 1].tag) else 255;
            // Also the return value we're about to log.
            dbg_pp_cap_ret = if (result_in.tag == .number) result_in.data.number else -1;
            // Capture PP's CALLER (frame_count-2) func + its local slots, to find
            // what computed the divergent g (bit-count) argument.
            if (frame_count >= 2) {
                const cf = frames[frame_count - 2];
                dbg_pp_caller_func = cf.func_id;
                dbg_pp_caller_ip = cf.ip;
                var ci: usize = 0;
                while (ci < 16 and cf.bp + ci < MAX_STACK) : (ci += 1) {
                    const sv = stack[cf.bp + ci];
                    dbg_pp_caller_num[ci] = if (sv.tag == .number) sv.data.number else -999999;
                }
            }
            // Capture the full call-stack (func_id @ ip) at the divergence, so the
            // DISPATCH decision (which chose G varint vs sT plain reader) is visible.
            dbg_pp_stack_n = 0;
            { var si: usize = frame_count; while (si > 0 and dbg_pp_stack_n < dbg_pp_stack_func.len) { si -= 1;
                dbg_pp_stack_func[dbg_pp_stack_n] = frames[si].func_id;
                dbg_pp_stack_ip[dbg_pp_stack_n] = frames[si].ip;
                dbg_pp_stack_n += 1; } }
            // Capture the DISPATCHER frame's (frame_count-3) locals — the func that
            // chose G vs sT (branch `local8 >= local6`). These values decide the read.
            if (frame_count >= 3) {
                const df = frames[frame_count - 3];
                dbg_pp_disp_func = df.func_id;
                dbg_pp_disp_ip = df.ip;
                var di: usize = 0;
                while (di < 16 and df.bp + di < MAX_STACK) : (di += 1) {
                    const dv = stack[df.bp + di];
                    dbg_pp_disp_num[di] = if (dv.tag == .number) dv.data.number else -999999;
                    dbg_pp_disp_tag[di] = @intFromEnum(dv.tag);
                }
            }
            // Capture the STATE-MACHINE frame (frame_count-4 = func 286) local 38
            // (the interpreter state var driving the handler dispatch) + a window
            // of locals 36..48 to compare the state against the oracle.
            if (frame_count >= 4) {
                const sf = frames[frame_count - 4];
                dbg_pp_sm_func = sf.func_id;
                var si2: usize = 0;
                while (si2 < 16 and sf.bp + 36 + si2 < MAX_STACK) : (si2 += 1) {
                    const sv2 = stack[sf.bp + 36 + si2];
                    dbg_pp_sm_num[si2] = if (sv2.tag == .number) sv2.data.number else -999999;
                    dbg_pp_sm_tag[si2] = @intFromEnum(sv2.tag);
                }
            }
            // slots: 0=this,1=b,2=x,3=g (PP=function(b,x,g,...))
            dbg_pp_cap_b_tag = if (fr.bp + 1 < MAX_STACK) @intFromEnum(stack[fr.bp + 1].tag) else 255;
            dbg_pp_cap_b_num = if (fr.bp + 1 < MAX_STACK and stack[fr.bp + 1].tag == .number) stack[fr.bp + 1].data.number else -1;
            dbg_pp_cap_g_num = if (fr.bp + 3 < MAX_STACK and stack[fr.bp + 3].tag == .number) stack[fr.bp + 3].data.number else -1;
            // x = the decoder-state object; read x.v (limit), x.WO (word array).
            if (fr.bp + 2 < MAX_STACK and (stack[fr.bp + 2].tag == .object or stack[fr.bp + 2].tag == .array)) {
                const xo = stack[fr.bp + 2].data.obj_idx;
                const vv = objects.getProperty(xo, values.internString("v"));
                dbg_pp_cap_xv = if (vv.tag == .number) vv.data.number else -1;
                // Decoder state: x.B (block base) and x.O (block index).
                const bprop = objects.getProperty(xo, values.internString("B"));
                dbg_pp_cap_xB = if (bprop.tag == .number) bprop.data.number else -999999;
                const oprop = objects.getProperty(xo, values.internString("O"));
                dbg_pp_cap_xO = if (oprop.tag == .number) oprop.data.number else (if (oprop.tag == .undefined) -2 else -999999);
                // x.F (decode-state flag: F? hk(x,x.I) : PP(x,8)), x.I, x.AP.
                dbg_pp_cap_xF = @intFromEnum(objects.getProperty(xo, values.internString("F")).tag);
                const iprop = objects.getProperty(xo, values.internString("I"));
                dbg_pp_cap_xI = if (iprop.tag == .number) iprop.data.number else -999999;
                dbg_pp_cap_xAP = @intFromEnum(objects.getProperty(xo, values.internString("AP")).tag);
                const wo = objects.getProperty(xo, values.internString("WO"));
                dbg_pp_cap_wo_tag = @intFromEnum(wo.tag);
                if (wo.tag == .object or wo.tag == .array) {
                    const woidx = wo.data.obj_idx;
                    dbg_pp_cap_wo_len = objects.arrayLength(woidx);
                    // Sample WO words AT our ACTUAL read position (p>>3).
                    const base: u32 = if (dbg_pp_cap_p_actual >= 0) @intFromFloat(@divFloor(dbg_pp_cap_p_actual, 8)) else 0;
                    var wi: usize = 0;
                    while (wi < 8 and base + wi < objects.arrayLength(woidx)) : (wi += 1) {
                        const wv = objects.getArrayElement(woidx, @intCast(base + wi));
                        dbg_pp_cap_wo_sample[wi] = if (wv.tag == .number) wv.data.number else -1;
                        // ALSO read via the VM's get_elem path (what PP actually uses:
                        // F=x.WO[Y]) to detect a numeric-key get_elem divergence.
                        const wv2 = getElemFromValue(wo, Value.number(@floatFromInt(base + wi)));
                        dbg_pp_cap_wo_sample2[wi] = if (wv2.tag == .number) wv2.data.number else (if (wv2.tag == .undefined) -2 else -1);
                    }
                    dbg_pp_cap_wo_objtype = @intFromEnum(objects.objTypeOf(woidx));
                }
                // x.Y[166] length (= Lt.length; the `z==96: Lt.length>4?50:38` branch input).
                const yprop = objects.getProperty(xo, values.internString("Y"));
                if (yprop.tag == .object or yprop.tag == .array) {
                    const r166 = getElemFromValue(yprop, Value.number(166));
                    if (r166.tag == .object or r166.tag == .array) {
                        dbg_pp_r166_len = objects.arrayLength(r166.data.obj_idx);
                    } else { dbg_pp_r166_len = if (r166.tag == .undefined) 0xFFFFFFFE else 0xFFFFFFFD; }
                    const r169 = getElemFromValue(yprop, Value.number(169));
                    if (r169.tag == .object or r169.tag == .array) dbg_pp_r169_len = objects.arrayLength(r169.data.obj_idx) else dbg_pp_r169_len = 0xFFFFFFFF;
                }
                // D = x.IP.length (used as the keystream mask: x.Yt[Y & D]).
                const ipprop = objects.getProperty(xo, values.internString("IP"));
                if (ipprop.tag == .object or ipprop.tag == .array) {
                    dbg_pp_cap_ip_len = objects.arrayLength(ipprop.data.obj_idx);
                } else { dbg_pp_cap_ip_len = if (ipprop.tag == .undefined) 0xFFFFFFFE else 0xFFFFFFFD; }
                // x.Yt = keystream array (from mS). Capture length + first 8 bytes.
                const ytprop = objects.getProperty(xo, values.internString("Yt"));
                if (ytprop.tag == .object or ytprop.tag == .array) {
                    const ytidx = ytprop.data.obj_idx;
                    dbg_pp_cap_yt_len = objects.arrayLength(ytidx);
                    var yi: usize = 0;
                    while (yi < 8 and yi < objects.arrayLength(ytidx)) : (yi += 1) {
                        const yv = objects.getArrayElement(ytidx, @intCast(yi));
                        dbg_pp_cap_yt_sample[yi] = if (yv.tag == .number) yv.data.number else -1;
                    }
                } else { dbg_pp_cap_yt_len = 0xFFFFFFFF; }
            }
        }
        dbg_pp_n += 1;
    }
    // ── Full register-read logger: at Q (dbg_qr_qid) / v (dbg_qr_vid) return,
    // log 'Q<reg>=<val>' (reg from the param slot; val fmt matches oracle __qallfmt).
    if ((dbg_qr_qid != 0xFFFF or dbg_qr_vid != 0xFFFF) and frame_count > 0 and dbg_qr_n < dbg_qr_cap) {
        const qf = frames[frame_count - 1];
        var reg_slot: u32 = 0; var is_rr = false;
        if (qf.func_id == dbg_qr_qid) { reg_slot = qf.bp + 1; is_rr = true; } // Q(b=reg,...)
        else if (qf.func_id == dbg_qr_vid) { reg_slot = qf.bp + 2; is_rr = true; } // v(b,x=reg,...)
        else if (qf.func_id == dbg_qr_eid) { reg_slot = qf.bp + 1; is_rr = true; } // e(b=reg,x,g)
        if (is_rr and reg_slot < MAX_STACK) {
            const rv = stack[reg_slot];
            if (rv.tag == .number) {
                dbg_qr_reg[dbg_qr_n] = @intFromFloat(rv.data.number);
                // Format result: number→unsigned; object/array→o/e0/e1/e2.
                if (result.tag == .number) {
                    dbg_qr_isobj[dbg_qr_n] = 0;
                    dbg_qr_val[dbg_qr_n] = result.data.number;
                } else if (result.tag == .object or result.tag == .array or result.tag == .function) {
                    dbg_qr_isobj[dbg_qr_n] = 1;
                    const oi = result.data.obj_idx;
                    var k: usize = 0;
                    while (k < 3) : (k += 1) {
                        const ev = objects.getArrayElement(oi, @intCast(k));
                        dbg_qr_e[dbg_qr_n][k] = if (ev.tag == .number) ev.data.number else -987654.0;
                    }
                } else { dbg_qr_isobj[dbg_qr_n] = 2; }
                dbg_qr_n += 1;
            }
        }
    }
    // ── Decoder-construction return trace.
    if (frame_count > 0) {
        const rf = frames[frame_count - 1].func_id;
        if (rf == dbg_dec_m6_id) {
            dbg_dec_m6_rets += 1;
            // Arm the property-node guard on obj520's "H" node now that M6 has
            // established W.H=W. Only arm once.
            if (objects.dbgGuardNode() == 0xFFFFFFFF) {
                const hn = objects.dbgFindPropNodeByChar(520, 'H');
                if (hn != objects.NULL_PROP) objects.dbgGuardNodeSet(hn);
            }
        }
        if (rf == dbg_dec_ch_id and dbg_dec_ch_ret_tag == 255) {
            // Capture ch's return (after ctor substitution it would be the obj,
            // but this is the raw body return BEFORE the ctor_is substitution
            // which happens a few lines below).
            dbg_dec_ch_ret_tag = @intFromEnum(result.tag);
            dbg_dec_ch_ret_obj = if (result.tag == .object or result.tag == .array or result.tag == .function) result.data.obj_idx else 0xFFFFFFFF;
        }
    }
    // Close upvalues captured from this frame's locals before its stack slots
    // are discarded, so closures (e.g. BotGuard's Me capturing Ne/pL) keep
    // seeing the final values after the defining frame returns.
    if (frame_count > 0) closeUpvalues(frames[frame_count - 1].bp);
    // Constructor frame: a `new` call returns the constructed object unless the
    // body explicitly returned an object.
    const idx = frame_count - 1;
    if (idx < MAX_FRAMES and ctor_is[idx]) {
        ctor_is[idx] = false;
        if (result.tag != .object and result.tag != .array and result.tag != .function) {
            result = Value.object(ctor_new_obj[idx]);
        }
    }

    if (frame_count <= 1) {
        // Top-level return — push result and stop
        push(result);
        frame_count = 0;
        return;
    }

    const frame = frames[frame_count - 1];
    // bp points at the callee slot (slot 0) for normal calls, or at the
    // reserved this-slot for eval frames. In both cases resetting sp to bp
    // discards the whole frame (callee/this + args + locals); the result is
    // then pushed in the callee slot's place.
    sp = @intCast(frame.bp);
    frame_count -= 1;
    // Pop any try frames that belonged to the frame we just left. A function
    // can `return` from inside a `try` without ever executing `leave_try`,
    // leaving a stale TryFrame on the stack. If a later `throw` in a different
    // frame walks the try stack, it would unwind into this dead frame and
    // corrupt frame_count / ip (runaway loop). enter_try records
    // frame_depth = frame_count (the depth the try lives at), so anything with
    // frame_depth > frame_count now refers to a frame that no longer exists.
    while (try_count > 0 and try_frames[try_count - 1].frame_depth > frame_count) {
        try_count -= 1;
    }
    push(result);
}

/// Build a JS Error-like object { name, message } with the shared error
/// prototype (which provides toString -> "name: message"). Used for both the
/// `Error(...)`/`ReferenceError(...)` constructors and VM-raised errors.
pub fn makeErrorObject(name: []const u8, message: []const u8) Value {
    const o = objects.createObject();
    objects.setProperty(o, values.internString("name"), Value.string(values.internString(name)));
    objects.setProperty(o, values.internString("message"), Value.string(values.internString(message)));
    // JS Error objects carry a `.stack` string. BotGuard's error-encoding path
    // (`uI`) reads `n.stack`, appends it to the transcript, and DEBITS an error
    // budget (register 73[0], initialised to 2048) by `stack.length + 3` per
    // encoded error. In V8 the stack is ~1600 bytes (deep eval frames), so two
    // errors exhaust the 2048 budget and the third error (oc=97 "replace") does
    // NOT emit — its uI loop guard `H[0] > 3` is false. A too-short stack (the
    // previous minimal form was ~40 bytes) leaves the budget nearly full, so our
    // VM kept emitting at oc=97, reading extra registers (J368/J41/q76) and
    // drifting the whole register decode (dispatch diverged at oc=347).
    //
    // BotGuard does not parse the stack — it only encodes its bytes and counts
    // its length. So we synthesise a V8-shaped stack of realistic length so the
    // budget depletes on the same schedule as the reference engine.
    var sbuf: [2048]u8 = undefined;
    var sn: usize = 0;
    const appendStr = struct {
        fn f(dst: []u8, pos: *usize, s: []const u8) void {
            const take = @min(s.len, dst.len - pos.*);
            @memcpy(dst[pos.* .. pos.* + take], s[0..take]);
            pos.* += take;
        }
    }.f;
    appendStr(&sbuf, &sn, name);
    appendStr(&sbuf, &sn, ": ");
    appendStr(&sbuf, &sn, message);
    // Synthetic frames. V8's real frames name interpreter helpers (eval, vb, ...)
    // and carry <anonymous>:652:<col> source positions. Emit varied frames until
    // the stack reaches BotGuard's typical ~1590-byte magnitude (< 2048 buffer).
    const frame_fns = [_][]const u8{ "eval", "vb", "es", "Pz", "wN", "YG", "dg", "Sz", "lo", "Fm", "V", "q", "Z", "J", "u", "D" };
    var fi: usize = 0;
    var col: usize = 34720;
    while (sn < 1590 and sn + 96 < sbuf.len) : (fi += 1) {
        const fname = frame_fns[fi % frame_fns.len];
        appendStr(&sbuf, &sn, "\n    at ");
        appendStr(&sbuf, &sn, fname);
        appendStr(&sbuf, &sn, " (eval at <anonymous> (<anonymous>:1:15), <anonymous>:652:");
        // decimal column, pseudo-varied
        var cbuf: [8]u8 = undefined;
        var cn: usize = 0;
        var c = col;
        if (c == 0) {
            cbuf[0] = '0';
            cn = 1;
        } else {
            var tmp: [8]u8 = undefined;
            var tn: usize = 0;
            while (c > 0) : (c /= 10) {
                tmp[tn] = @intCast('0' + (c % 10));
                tn += 1;
            }
            while (tn > 0) : (tn -= 1) {
                cbuf[cn] = tmp[tn - 1];
                cn += 1;
            }
        }
        appendStr(&sbuf, &sn, cbuf[0..cn]);
        appendStr(&sbuf, &sn, ")");
        col = if (col > 137) col - 137 else col + 4099;
    }
    objects.setProperty(o, values.internString("stack"), Value.string(values.internString(sbuf[0..sn])));
    objects.setObjectPrototype(o, objects.getErrorProto());
    return Value.object(o);
}

/// Raise a ReferenceError("<name> is not defined") through the VM's try/catch
/// unwinder — matching JS semantics for reading an undeclared global. BotGuard's
/// feature detection and error-encoding paths depend on this throwing.
fn throwReferenceError(var_name: []const u8) void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    const suffix = " is not defined";
    const nm = var_name[0..@min(var_name.len, buf.len - suffix.len - 1)];
    @memcpy(buf[0..nm.len], nm);
    n = nm.len;
    @memcpy(buf[n .. n + suffix.len], suffix);
    n += suffix.len;
    recordThrowMsg(buf[0..n]);
    // Capture context of the FIRST ReferenceError (which var, which func_id/ip),
    // to locate why a top-level helper (e.g. `Eu`) fails to resolve.
    if (!dbg_referr_captured) {
        dbg_referr_captured = true;
        const k = @min(var_name.len, dbg_referr_name.len);
        @memcpy(dbg_referr_name[0..k], var_name[0..k]);
        dbg_referr_name_len = k;
        if (frame_count > 0) { dbg_referr_func = frames[frame_count - 1].func_id; dbg_referr_ip = frames[frame_count - 1].ip; dbg_referr_closure = frames[frame_count - 1].closure_obj; }
    }
    const err = makeErrorObject("ReferenceError", buf[0..n]);
    had_error = true;
    throwException(err);
}
pub var dbg_referr_captured: bool = false;
pub var dbg_referr_name: [32]u8 = undefined;
pub var dbg_referr_name_len: usize = 0;
pub var dbg_referr_func: u16 = 0xFFFF;
pub var dbg_referr_ip: u32 = 0;
pub var dbg_referr_closure: u32 = 0xFFFFFFFF;
pub fn dbgReferrName() []const u8 { return dbg_referr_name[0..dbg_referr_name_len]; }
pub fn dbgReferr() [3]u32 { return .{ dbg_referr_func, dbg_referr_ip, dbg_referr_closure }; }

/// Raise TypeError for reading/writing a property of undefined or null. JS:
/// `undefined.x` / `null.x` throw "Cannot read properties of undefined
/// (reading 'x')". BotGuard's feature detection (e.g. probing
/// `trustedTypes.constructor` inside try/catch) DEPENDS on this throwing — if
/// we silently return undefined, the code takes the wrong branch and stores an
/// undefined where a real value is expected.
// Record up to 8 thrown-exception descriptions for diagnostics.
pub var dbg_throwmsg: [8][96]u8 = undefined;
pub var dbg_throwmsg_len: [8]usize = [_]usize{0} ** 8;
pub var dbg_throwmsg_n: usize = 0;
fn recordThrowMsg(msg: []const u8) void {
    if (dbg_throwmsg_n >= dbg_throwmsg.len) return;
    const n = @min(msg.len, 96);
    @memcpy(dbg_throwmsg[dbg_throwmsg_n][0..n], msg[0..n]);
    dbg_throwmsg_len[dbg_throwmsg_n] = n;
    dbg_throwmsg_n += 1;
}
pub fn dbgThrowMsgCount() usize { return dbg_throwmsg_n; }
pub fn dbgThrowMsg(i: usize) []const u8 { if (i >= dbg_throwmsg_n) return ""; return dbg_throwmsg[i][0..dbg_throwmsg_len[i]]; }

// Ring of ALL cannot-read-prop throws (live-challenge undefined-receiver enum).
pub var dbg_crpring_n: usize = 0;
pub var dbg_crpring_func: [64]u16 = [_]u16{0xFFFF} ** 64;
pub var dbg_crpring_ip: [64]u32 = [_]u32{0} ** 64;
pub var dbg_crpring_prop: [64][24]u8 = [_][24]u8{[_]u8{0} ** 24} ** 64;
pub var dbg_crpring_proplen: [64]usize = [_]usize{0} ** 64;
pub var dbg_crpring_recv: [64][24]u8 = [_][24]u8{[_]u8{0} ** 24} ** 64;
pub var dbg_crpring_recvlen: [64]usize = [_]usize{0} ** 64;
pub fn dbgCrpRingN() usize { return dbg_crpring_n; }
pub fn dbgCrpRingFunc(i: usize) u16 { return dbg_crpring_func[i]; }
pub fn dbgCrpRingIp(i: usize) u32 { return dbg_crpring_ip[i]; }
pub fn dbgCrpRingProp(i: usize) []const u8 { return dbg_crpring_prop[i][0..dbg_crpring_proplen[i]]; }
pub fn dbgCrpRingRecv(i: usize) []const u8 { return dbg_crpring_recv[i][0..dbg_crpring_recvlen[i]]; }

pub var dbg_crp_op: [40]u8 = [_]u8{0} ** 40;
pub var dbg_crp_op_n: usize = 0;
pub var dbg_crp_prop: [32]u8 = undefined;
pub var dbg_crp_prop_len: usize = 0;
pub var dbg_crp_captured: bool = false;
pub var dbg_crp_func: u16 = 0xFFFF;
pub var dbg_crp_ip: u32 = 0;
pub var dbg_crp_gn: usize = 0;
pub var dbg_capture_on_throw: bool = false;
pub fn dbgCrpFunc() u16 { return dbg_crp_func; }
pub fn dbgCrpIp() u32 { return dbg_crp_ip; }
pub fn dbgCrpOpCount() usize { return dbg_crp_op_n; }
pub fn dbgCrpOpName(i: usize) []const u8 { if (i >= dbg_crp_op_n) return ""; return @tagName(@as(Op, @enumFromInt(dbg_crp_op[i]))); }
pub fn dbgCrpProp() []const u8 { return dbg_crp_prop[0..dbg_crp_prop_len]; }

fn throwCannotReadProp(is_null: bool, prop_name: []const u8) void {
    dbgTraceFailure(values.internString(prop_name));
    // RING: record EVERY cannot-read-prop (func/ip/prop/prior-lookup-name) so the
    // intermittent live-challenge undefined-receiver reads can all be enumerated
    // across runs (not just the first). prev_lookup_name = the lookup that
    // produced the undefined/null receiver.
    if (dbg_crpring_n < dbg_crpring_func.len) {
        const k = dbg_crpring_n;
        dbg_crpring_func[k] = if (frame_count > 0) frames[frame_count - 1].func_id else 0xFFFF;
        dbg_crpring_ip[k] = if (frame_count > 0) frames[frame_count - 1].ip else 0;
        const pn = @min(prop_name.len, 24);
        @memcpy(dbg_crpring_prop[k][0..pn], prop_name[0..pn]);
        dbg_crpring_proplen[k] = pn;
        const rcv = if (prev_lookup_name != 0) values.getString(prev_lookup_name) else "";
        const rn = @min(rcv.len, 24);
        @memcpy(dbg_crpring_recv[k][0..rn], rcv[0..rn]);
        dbg_crpring_recvlen[k] = rn;
        dbg_crpring_n += 1;
    }
    // Debug: record which prior lookup produced the undefined/null receiver, so
    // we can identify the env object/chain that's missing (payload-inflating).
    if (dbg_mm_probe) recordMethodMiss(if (prev_lookup_name != 0) prev_lookup_name else last_lookup_name, 200, false);
    // Capture the FH frame's local 6 (F) tag/objidx at the 'length' throw, so we
    // can see whether F (the decoder) is a function (wrong) or object.
    if (!dbg_fh_captured and prop_name.len == 6 and prop_name[0] == 'l' and frame_count > 0) {
        const fr = frames[frame_count - 1];
        const l6 = fr.bp + 6;
        if (l6 < MAX_STACK) {
            dbg_fh_captured = true;
            dbg_fh_l6_tag = @intFromEnum(stack[l6].tag);
            dbg_fh_l6_obj = if (stack[l6].tag == .object or stack[l6].tag == .array or stack[l6].tag == .function) stack[l6].data.obj_idx else 0xFFFFFFFF;
            dbg_fh_func = fr.func_id;
            // Record the raw number value of F (if F is a number) and the
            // CALLER (which FH call site fired): caller func + caller ip.
            dbg_fh_l6_num = if (stack[l6].tag == .number) stack[l6].data.number else -987654.0;
            if (frame_count >= 2) { dbg_fh_caller_func = frames[frame_count - 2].func_id; dbg_fh_caller_ip = frames[frame_count - 2].ip; }
            // Also capture FH's other params for context: b(l1),x(l2),g(l3),Y(l4),L(l5).
            dbg_fh_l3_tag = if (fr.bp + 3 < MAX_STACK) @intFromEnum(stack[fr.bp + 3].tag) else 255;
            dbg_fh_l4_num = if (fr.bp + 4 < MAX_STACK and stack[fr.bp + 4].tag == .number) stack[fr.bp + 4].data.number else -987654.0;
        }
    }
    // Capture the opcode ring + IP at the FIRST cannot-read throw for analysis.
    if (dbg_mm_probe and !dbg_crp_captured) {
        dbg_crp_captured = true;
        dbg_crp_gn = dbg_gtrace_n;
        if (dbg_capture_on_throw) {
            dbg_gtrace_cap_n = @min(frame_count, dbg_gtrace_cap_slots.len);
            for (0..dbg_gtrace_cap_n) |i| {
                const captured = frames[frame_count - 1 - i];
                dbg_gtrace_cap_func[i] = captured.func_id;
                dbg_gtrace_cap_ip[i] = captured.ip;
                for (0..16) |j| dbg_gtrace_cap_slots[i][j] = if (captured.bp + j < MAX_STACK) stack[captured.bp + j] else Value.UNDEFINED;
                for (0..32) |j| {
                    var value = Value.UNDEFINED;
                    if (captured.closure_obj != objects.NULL_OBJ and j < objects.closureUpvalCount(captured.closure_obj)) {
                        if (objects.isClosureUpvalClosed(captured.closure_obj, @intCast(j))) value = objects.getClosureUpvalClosedVal(captured.closure_obj, @intCast(j))
                        else {
                            const address = objects.getClosureUpvalAddr(captured.closure_obj, @intCast(j));
                            if (address != objects.NO_UPVAL_ADDR and address < MAX_STACK) value = stack[address];
                        }
                    }
                    dbg_gtrace_cap_upvals[i][j] = value;
                }
            }
        }
        if (frame_count > 0) { dbg_crp_func = frames[frame_count - 1].func_id; dbg_crp_ip = frames[frame_count - 1].ip; }
        const pl = @min(prop_name.len, dbg_crp_prop.len);
        @memcpy(dbg_crp_prop[0..pl], prop_name[0..pl]);
        dbg_crp_prop_len = pl;
        dbg_crp_op_n = 0;
        const oc = @min(op_ring.len, op_ring_pos);
        var oj: usize = 0;
        while (oj < oc and dbg_crp_op_n < dbg_crp_op.len) : (oj += 1) {
            const oi = (op_ring_pos - oc + oj) % op_ring.len;
            dbg_crp_op[dbg_crp_op_n] = op_ring[oi];
            dbg_crp_op_n += 1;
        }
    }
    var buf: [160]u8 = undefined;
    const p1 = "Cannot read properties of ";
    const which: []const u8 = if (is_null) "null" else "undefined";
    const p2 = " (reading '";
    const p3 = "')";
    var n: usize = 0;
    inline for (.{ p1, which, p2 }) |seg| {
        const take = @min(seg.len, buf.len - n);
        @memcpy(buf[n .. n + take], seg[0..take]);
        n += take;
    }
    const pn = prop_name[0..@min(prop_name.len, buf.len - n - p3.len)];
    @memcpy(buf[n .. n + pn.len], pn);
    n += pn.len;
    @memcpy(buf[n .. n + p3.len], p3);
    n += p3.len;
    const err = makeErrorObject("TypeError", buf[0..n]);
    had_error = true;
    throwException(err);
}

/// Raise a TypeError with an arbitrary message. Used to surface a throw
/// requested by a native builtin (builtins.native_throw), e.g.
/// String.prototype.toString applied to a non-String `this`.
fn throwCannotSetProp(is_null: bool, name: ?[]const u8) void {
    var buffer: [256]u8 = undefined;
    const base = if (is_null) "null" else "undefined";
    const prefix = "Cannot set properties of ";
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..base.len], base);
    var length = prefix.len + base.len;
    if (name) |property| {
        const setting = " (setting '";
        @memcpy(buffer[length..][0..setting.len], setting); length += setting.len;
        const take = @min(property.len, buffer.len - length - 2);
        @memcpy(buffer[length..][0..take], property[0..take]); length += take;
        @memcpy(buffer[length..][0..2], "')"); length += 2;
    }
    throwTypeErrorMsg(buffer[0..length]);
}
fn throwTypeErrorMsg(msg: []const u8) void {
    if (operation_aborted) return;
    const err = makeErrorObject("TypeError", msg);
    had_error = true;
    throwException(err);
}
fn throwRangeErrorMsg(msg: []const u8) void {
    if (operation_aborted) return;
    had_error = true;
    throwException(makeErrorObject("RangeError", msg));
}

/// If the most recent native call requested a throw, convert it into a real VM
/// TypeError throw. Returns true if a throw was raised (caller must return).
fn checkNativeThrow() bool {
    if (operation_aborted) { builtins.native_throw = false; return true; }
    if (!builtins.native_throw) return false;
    builtins.native_throw = false;
    const err = makeErrorObject(builtins.native_throw_name, builtins.nativeThrowMsg());
    had_error = true;
    throwException(err);
    return true;
}

/// Raise TypeError("<name> is not a function") when a non-callable value is
/// invoked (JS semantics). BotGuard's feature detection depends on this.
pub var dbg_failure_n: usize = 0;
pub var dbg_failure_func: [16]u16 = undefined;
pub var dbg_failure_gn: [16]usize = undefined;
pub var dbg_failure_name: [16]u32 = undefined;
pub var dbg_failure_locals: [16][32]Value = undefined;
pub var dbg_failure_upvals: [16][64]Value = undefined;
fn dbgTraceFailure(name_idx: u32) void {
    if (!dbg_gtrace_on or dbg_failure_n >= dbg_failure_func.len or frame_count == 0) return;
    const i = dbg_failure_n;
    const frame = frames[frame_count - 1];
    dbg_failure_func[i] = frame.func_id;
    dbg_failure_gn[i] = dbg_gtrace_n;
    dbg_failure_name[i] = name_idx;
    for (0..32) |j| dbg_failure_locals[i][j] = if (frame.bp + j < sp) stack[frame.bp + j] else Value.UNDEFINED;
    for (0..64) |j| {
        var v = Value.UNDEFINED;
        if (frame.closure_obj != objects.NULL_OBJ and j < objects.closureUpvalCount(frame.closure_obj)) {
            if (objects.isClosureUpvalClosed(frame.closure_obj, @intCast(j))) v = objects.getClosureUpvalClosedVal(frame.closure_obj, @intCast(j))
            else { const a = objects.getClosureUpvalAddr(frame.closure_obj, @intCast(j)); if (a != objects.NO_UPVAL_ADDR and a < MAX_STACK) v = stack[a]; }
        }
        dbg_failure_upvals[i][j] = v;
    }
    dbg_failure_n += 1;
}
fn throwNotAFunction(name_idx: u32) void {
    dbgTraceFailure(name_idx);
    const nm = values.getString(name_idx);
    var buf: [128]u8 = undefined;
    const suffix = " is not a function";
    const use = nm[0..@min(nm.len, buf.len - suffix.len - 1)];
    @memcpy(buf[0..use.len], use);
    @memcpy(buf[use.len .. use.len + suffix.len], suffix);
    recordThrowMsg(buf[0 .. use.len + suffix.len]);
    const err = makeErrorObject("TypeError", buf[0 .. use.len + suffix.len]);
    had_error = true;
    throwException(err);
}

/// Raise TypeError "<recv>.<method> is not a function" for a non-callable method
/// call `recv.method(...)` (JS semantics — V8 includes the full member path in
/// the message, e.g. "Y.apply is not a function"). BotGuard deliberately calls
/// non-callable methods to generate this error into its transcript, so the
/// message MUST match. If the receiver name is unknown (0), fall back to the
/// bare "<method> is not a function" form.
pub var dbg_nafm_captured: bool = false;
pub var dbg_nafm_func: u16 = 0xFFFF;
pub var dbg_nafm_ip: u32 = 0;
pub var dbg_nafm_recv: u32 = 0;
pub var dbg_nafm_method: u32 = 0;
pub fn dbgNafmFunc() u16 { return dbg_nafm_func; }
pub fn dbgNafmIp() u32 { return dbg_nafm_ip; }
pub fn dbgNafmRecv() []const u8 { return values.getString(dbg_nafm_recv); }
pub fn dbgNafmMethod() []const u8 { return values.getString(dbg_nafm_method); }

// Push-specific failure capture (what `t` is when `t.push` is not callable).
pub var dbg_pushfail_captured: bool = false;
pub var dbg_pushfail_recv_tag: u8 = 255;
pub var dbg_pushfail_recv_obj: u32 = 0xFFFFFFFF;
pub var dbg_pushfail_recv_objtype: u8 = 255;
pub var dbg_pushfail_recv_arrlen: u32 = 0;
pub var dbg_pushfail_recv_proto: u32 = 0xFFFFFFFF;
pub var dbg_pushfail_recv_propcount: u32 = 0;
pub var dbg_pushfail_arrayproto: u32 = 0xFFFFFFFF;
pub var dbg_pushfail_proto_has_push: u8 = 0;
pub var dbg_pushfail_push_owner: u32 = 0xFFFFFFFF;
pub var dbg_pushfail_func: u16 = 0xFFFF;
pub var dbg_pushfail_ip: u32 = 0;
pub var dbg_pushfail_str_idx: u32 = 0;
pub var dbg_pushfail_str: [256]u8 = undefined;
pub var dbg_pushfail_str_len: usize = 0;
// func-40 (cell .concat) capture: [0]=string-return (bad reg116), [1]=array-return (good reg)
pub var dbg_f40_str_done: bool = false;
pub var dbg_f40_arr_done: bool = false;
pub var dbg_f40_rtag: [2]u8 = [_]u8{255} ** 2;
pub var dbg_f40_p: [2]f64 = [_]f64{-987654.0} ** 2;
pub var dbg_f40_fstr: [2][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 2;
pub var dbg_f40_fslen: [2]usize = [_]usize{0} ** 2;
pub var dbg_f40_uvcount: [2]u16 = [_]u16{0} ** 2;
pub var dbg_f40_uvtag: [2][12]u8 = [_][12]u8{[_]u8{255} ** 12} ** 2;
pub var dbg_f40_uvnum: [2][12]f64 = [_][12]f64{[_]f64{-987654.0} ** 12} ** 2;
pub var dbg_f40_glen: [2]u32 = [_]u32{0} ** 2;
pub var dbg_f40_guv: [2]u16 = [_]u16{0xFFFF} ** 2;
pub var dbg_f40_gtag: [2][16]u8 = [_][16]u8{[_]u8{255} ** 16} ** 2;
pub var dbg_f40_gnum: [2][16]f64 = [_][16]f64{[_]f64{-987654.0} ** 16} ** 2;
pub var dbg_f40_gp_tag: [2]u8 = [_]u8{255} ** 2;
pub var dbg_f40_gstr: [2][16][16]u8 = [_][16][16]u8{[_][16]u8{[_]u8{0} ** 16} ** 16} ** 2;
pub var dbg_f40_gstrlen: [2][16]usize = [_][16]usize{[_]usize{0} ** 16} ** 2;
pub fn dbgF40Gstr(i: usize, j: usize) []const u8 { return dbg_f40_gstr[i][j][0..dbg_f40_gstrlen[i][j]]; }
pub var dbg_f40_target_recv: u32 = 0xFFFFFFFF;
pub var dbg_f40ring_n: usize = 0;
pub var dbg_f40ring_rtag: [48]u8 = [_]u8{255} ** 48;
pub var dbg_f40ring_recv: [48]u32 = [_]u32{0xFFFFFFFF} ** 48;
pub var dbg_f40ring_p: [48]f64 = [_]f64{-987654.0} ** 48;
pub var dbg_f40ring_str: [48][40]u8 = [_][40]u8{[_]u8{0} ** 40} ** 48;
pub var dbg_f40ring_slen: [48]usize = [_]usize{0} ** 48;
pub fn dbgF40RingN() usize { return dbg_f40ring_n; }
pub fn dbgF40RingRtag(i: usize) u8 { return dbg_f40ring_rtag[i]; }
pub fn dbgF40RingRecv(i: usize) u32 { return dbg_f40ring_recv[i]; }
pub fn dbgF40RingP(i: usize) f64 { return dbg_f40ring_p[i]; }
pub fn dbgF40RingStr(i: usize) []const u8 { return dbg_f40ring_str[i][0..dbg_f40ring_slen[i]]; }
pub fn dbgF40Rtag(i: usize) u8 { return dbg_f40_rtag[i]; }
pub fn dbgF40P(i: usize) f64 { return dbg_f40_p[i]; }
pub fn dbgF40Fstr(i: usize) []const u8 { return dbg_f40_fstr[i][0..dbg_f40_fslen[i]]; }
pub fn dbgF40UvCount(i: usize) u16 { return dbg_f40_uvcount[i]; }
pub fn dbgF40UvTag(i: usize, j: usize) u8 { return dbg_f40_uvtag[i][j]; }
pub fn dbgF40UvNum(i: usize, j: usize) f64 { return dbg_f40_uvnum[i][j]; }
pub fn dbgF40Glen(i: usize) u32 { return dbg_f40_glen[i]; }
pub fn dbgF40Guv(i: usize) u16 { return dbg_f40_guv[i]; }
pub fn dbgF40Gtag(i: usize, j: usize) u8 { return dbg_f40_gtag[i][j]; }
pub fn dbgF40Gnum(i: usize, j: usize) f64 { return dbg_f40_gnum[i][j]; }
pub fn dbgF40GpTag(i: usize) u8 { return dbg_f40_gp_tag[i]; }
pub var dbg_vcallee_captured: bool = false;
pub var dbg_vcallee_func: u16 = 0xFFFF;
pub var dbg_vcallee_ip: u32 = 0;
pub var dbg_vcallee_str: [64]u8 = undefined;
pub var dbg_vcallee_str_len: usize = 0;
pub fn dbgVcalleeFunc() u16 { return dbg_vcallee_func; }
pub fn dbgVcalleeIp() u32 { return dbg_vcallee_ip; }
pub fn dbgVcalleeStr() []const u8 { return dbg_vcallee_str[0..dbg_vcallee_str_len]; }
pub var dbg_vret_captured: bool = false;
pub var dbg_vret_want_reg: i32 = 116;
pub var dbg_vret_result_tag: u8 = 255;
pub var dbg_vret_bank: u32 = 0xFFFFFFFF;
pub var dbg_vret_reg: i32 = -1;
pub var dbg_vret_cell: u32 = 0xFFFFFFFF;
pub var dbg_vret_cell_tag: u8 = 255;
pub var dbg_vret_str: [64]u8 = undefined;
pub var dbg_vret_str_len: usize = 0;
pub fn dbgVretResultTag() u8 { return dbg_vret_result_tag; }
pub fn dbgVretBank() u32 { return dbg_vret_bank; }
pub fn dbgVretReg() i32 { return dbg_vret_reg; }
pub fn dbgVretCell() u32 { return dbg_vret_cell; }
pub fn dbgVretCellTag() u8 { return dbg_vret_cell_tag; }
pub fn dbgVretStr() []const u8 { return dbg_vret_str[0..dbg_vret_str_len]; }
pub var dbg_pushfail_uvcount: u16 = 0;
pub var dbg_pushfail_uv_tag: [8]u8 = [_]u8{255} ** 8;
pub var dbg_pushfail_uv_closed: [8]u8 = [_]u8{0} ** 8;
pub var dbg_pushfail_uv_addr: [8]u32 = [_]u32{0xFFFFFFFF} ** 8;
pub var dbg_pushfail_483_bp: u32 = 0xFFFFFFFF;
pub var dbg_pushfail_483_local_tag: [10]u8 = [_]u8{255} ** 10;
pub var dbg_pushfail_483_local_num: [10]f64 = [_]f64{-987654.0} ** 10;
pub var dbg_pushfail_485_bp: u32 = 0xFFFFFFFF;
pub var dbg_pushfail_485_lc: u16 = 0;
pub fn dbgPushfail485Bp() u32 { return dbg_pushfail_485_bp; }
pub fn dbgPushfail485Lc() u16 { return dbg_pushfail_485_lc; }
pub var dbg_pushfail_483_x_obj: u32 = 0xFFFFFFFF;
pub var dbg_pushfail_483_g_obj: u32 = 0xFFFFFFFF;
pub fn dbgPushfail483XObj() u32 { return dbg_pushfail_483_x_obj; }
pub fn dbgPushfail483GObj() u32 { return dbg_pushfail_483_g_obj; }
pub fn dbgPushfailUvCount() u16 { return dbg_pushfail_uvcount; }
pub fn dbgPushfailUvTag(i: usize) u8 { return dbg_pushfail_uv_tag[i]; }
pub fn dbgPushfailUvClosed(i: usize) u8 { return dbg_pushfail_uv_closed[i]; }
pub fn dbgPushfailUvAddr(i: usize) u32 { return dbg_pushfail_uv_addr[i]; }
pub fn dbgPushfail483Bp() u32 { return dbg_pushfail_483_bp; }
pub fn dbgPushfail483LocalTag(i: usize) u8 { return dbg_pushfail_483_local_tag[i]; }
pub fn dbgPushfail483LocalNum(i: usize) f64 { return dbg_pushfail_483_local_num[i]; }
pub fn dbgPushfailStr() []const u8 { return dbg_pushfail_str[0..dbg_pushfail_str_len]; }
pub fn dbgPushfailTag() u8 { return dbg_pushfail_recv_tag; }
pub fn dbgPushfailObj() u32 { return dbg_pushfail_recv_obj; }
pub fn dbgPushfailObjType() u8 { return dbg_pushfail_recv_objtype; }
pub fn dbgPushfailArrLen() u32 { return dbg_pushfail_recv_arrlen; }
pub fn dbgPushfailProto() u32 { return dbg_pushfail_recv_proto; }
pub fn dbgPushfailPropCount() u32 { return dbg_pushfail_recv_propcount; }
pub fn dbgPushfailArrayProto() u32 { return dbg_pushfail_arrayproto; }
pub fn dbgPushfailProtoHasPush() u8 { return dbg_pushfail_proto_has_push; }
pub fn dbgPushfailPushOwner() u32 { return dbg_pushfail_push_owner; }
pub fn dbgPushfailFunc() u16 { return dbg_pushfail_func; }
pub fn dbgPushfailIp() u32 { return dbg_pushfail_ip; }

fn throwNotAFunctionMethod(recv_name_idx: u32, method_name_idx: u32) void {
    dbgTraceFailure(method_name_idx);
    // Capture the FIRST not-a-function-method throw location (func/ip) + names.
    if (!dbg_nafm_captured) {
        dbg_nafm_captured = true;
        if (frame_count > 0) { dbg_nafm_func = frames[frame_count - 1].func_id; dbg_nafm_ip = frames[frame_count - 1].ip; }
        dbg_nafm_recv = recv_name_idx;
        dbg_nafm_method = method_name_idx;
    }
    var buf: [160]u8 = undefined;
    var n: usize = 0;
    const recv = if (recv_name_idx != 0) values.getString(recv_name_idx) else "";
    const method = values.getString(method_name_idx);
    const suffix = " is not a function";
    if (recv.len > 0) {
        const rc = recv[0..@min(recv.len, buf.len - method.len - suffix.len - 2)];
        @memcpy(buf[n .. n + rc.len], rc);
        n += rc.len;
        buf[n] = '.';
        n += 1;
    }
    const mc = method[0..@min(method.len, buf.len - n - suffix.len)];
    @memcpy(buf[n .. n + mc.len], mc);
    n += mc.len;
    @memcpy(buf[n .. n + suffix.len], suffix);
    n += suffix.len;
    recordThrowMsg(buf[0..n]);
    const err = makeErrorObject("TypeError", buf[0..n]);
    had_error = true;
    throwException(err);
}

/// Raise TypeError "Cannot use 'in' operator to search for '<key>' in <rhs>"
/// for `key in rhs` where rhs is not an object (JS semantics). Returns true
/// (always throws). BotGuard uses `<x> in <number>` to force this error into its
/// transcript, so the message must match V8 exactly (key via String(key), rhs
/// via String(rhs)).
fn inOpThrow(key: Value, rhs: Value) bool {
    var buf: [192]u8 = undefined;
    var n: usize = 0;
    const p1 = "Cannot use 'in' operator to search for '";
    @memcpy(buf[0..p1.len], p1);
    n = p1.len;
    const key_s = values.getString(valueToStringIdx(key));
    {
        const kc = key_s[0..@min(key_s.len, buf.len - n - 8)];
        @memcpy(buf[n .. n + kc.len], kc);
        n += kc.len;
    }
    const mid = "' in ";
    @memcpy(buf[n .. n + mid.len], mid);
    n += mid.len;
    const rhs_s = values.getString(valueToStringIdx(rhs));
    {
        const rc = rhs_s[0..@min(rhs_s.len, buf.len - n)];
        @memcpy(buf[n .. n + rc.len], rc);
        n += rc.len;
    }
    recordThrowMsg(buf[0..n]);
    const err = makeErrorObject("TypeError", buf[0..n]);
    had_error = true;
    throwException(err);
    return true;
}

fn throwException(val: Value) void {
    error_value = val;
    if (dbg_first_throwex_tag == 255) {
        dbg_first_throwex_tag = @intFromEnum(val.tag);
        dbg_first_throwex_num = if (val.tag == .number) @intFromFloat(val.data.number) else -1;
    }
    dbg_throwex_count += 1;
    // If the thrown value is an array [op,30,z], record the register index z.
    // Arrays are stored as objects here; element[1]==30 marks a register-void fault.
    if (val.tag == .array or val.tag == .object) {
        const aoi: u32 = val.data.obj_idx;
        const e1 = objects.getArrayElement(aoi, 1);
        if (e1.tag == .number and @as(i64, @intFromFloat(e1.data.number)) == 30) {
            const e2 = objects.getArrayElement(aoi, 2);
            if (e2.tag == .number) {
                const zf: f64 = e2.data.number;
                const zi: i64 = @intFromFloat(zf);
                if (dbg_gtrace_on and zi == 12 and dbg_register_fault_depth == 0) {
                    dbg_register_fault_depth = @min(frame_count, dbg_register_fault_frames.len);
                    for (0..dbg_register_fault_depth) |i| {
                        const captured = frames[frame_count - 1 - i];
                        dbg_register_fault_frames[i] = captured.func_id;
                        for (0..16) |j| dbg_register_fault_locals[i][j] = if (captured.bp+j < MAX_STACK) stack[captured.bp+j] else Value.UNDEFINED;
                    }
                }
                dbg_regfault_total += 1;
                if (dbg_regfault_first_z < 0) {
                    dbg_regfault_first_z = zi;
                    // Retarget the element-access probe at the faulting register
                    // and reset its counters so we observe the resolve loop.
                    if (zi >= 0 and zi < 0x7FFFFFFF) {
                        objects.dbg_r311_target = @intCast(zi);
                        objects.dbg_r311_writes = 0;
                        objects.dbg_r311_reads = 0;
                        objects.dbg_r311_last_write_tag = 255;
                        objects.dbg_r311_last_read_tag = 255;
                        objects.dbg_r311_write_objs_n = 0;
                        objects.dbg_r311_read_objs_n = 0;
                    }
                    // Reset the call histogram so it captures only the calls
                    // made DURING the resolve loop that follows this fault.
                    { var hi: usize = 0; while (hi < dbg_fidhist.len) : (hi += 1) dbg_fidhist[hi] = 0; }
                    dbg_setelem_numeric = 0;
                    dbg_se_obj_n = 0;
                }
                if (dbg_regfault_first5_n < 5) { dbg_regfault_first5[dbg_regfault_first5_n] = zi; dbg_regfault_first5_n += 1; }
                if (zi >= 0 and zi < 65536) {
                    if (!dbg_regfault_seen[@intCast(zi)]) {
                        dbg_regfault_seen[@intCast(zi)] = true;
                        dbg_regfault_distinct += 1;
                    }
                }
            }
        }
    }
    // Record a description of every distinct exception routed through here.
    if (val.tag == .object) {
        const oi: u32 = val.data.obj_idx;
        const nm = objects.getProperty(oi, values.internString("name"));
        const ms = objects.getProperty(oi, values.internString("message"));
        var tb: [96]u8 = undefined;
        var tn: usize = 0;
        if (nm.tag == .string) { const s = values.getString(nm.data.str_idx); const k = @min(s.len, 40); @memcpy(tb[0..k], s[0..k]); tn = k; }
        else { const s = "obj"; @memcpy(tb[0..s.len], s); tn = s.len; }
        if (ms.tag == .string and tn < 90) { tb[tn] = ':'; tn += 1; const s = values.getString(ms.data.str_idx); const k = @min(s.len, 90 - tn); @memcpy(tb[tn .. tn + k], s[0..k]); tn += k; }
        recordThrowMsg(tb[0..tn]);
    } else if (val.tag == .string) {
        recordThrowMsg(values.getString(val.data.str_idx));
    } else {
        recordThrowMsg(@tagName(val.tag));
    }

    // Look for a try frame
    while (try_count > 0) {
        try_count -= 1;
        const tf = try_frames[try_count];
        const destination = if (tf.catch_ip != 0) tf.catch_ip else tf.finally_ip;
        if (destination != 0) discardFinallyOutside(tf.frame_depth, destination);

        // Unwind call frames
        if (frame_count > tf.frame_depth) closeUpvalues(frames[tf.frame_depth].bp);
        frame_count = tf.frame_depth;
        sp = tf.stack_depth;

        if (tf.catch_ip != 0) {
            // Jump to catch. had_error is cleared; enter_catch pushes the value.
            if (frame_count > 0) {
                frames[frame_count - 1].ip = tf.catch_ip;
            }
            had_error = false;
            return;
        }
        if (tf.finally_ip != 0) {
            // try WITHOUT catch (finally-only), or a catch that already ran and
            // whose finally must still execute during unwinding. Run the finally
            // block, then re-raise. We CLEAR had_error (so the dispatch loop
            // keeps running the finally body) but record a PENDING exception so
            // `leave_finally` re-throws it, propagating to the next enclosing
            // try/catch. Without this, a `try{throw}finally{}` inside an outer
            // try/catch would swallow the exception (outer catch never fires) —
            // BotGuard relies on finally-based unwinding.
            if (frame_count > 0) {
                frames[frame_count - 1].ip = tf.finally_ip;
            }
            staged_completion = .{ .kind = .exception, .value = error_value };
            had_error = false;
            dbg_finally_unwind += 1;
            return;
        }
    }

    // Unhandled — set the error flag (execution will stop).
    discardFinallyOutside(0, 0);
    staged_completion = null;
    fail("uncaught exception");
}

// ── Stack Operations ──

fn push(val: Value) void {
    if (operation_aborted) return;
    if (sp >= MAX_STACK) { fail("stack overflow"); return; }
    stack[sp] = val;
    sp += 1;
}

fn pop() Value {
    if (operation_aborted) return Value.UNDEFINED;
    if (sp == 0) return Value.UNDEFINED;
    sp -= 1;
    return stack[sp];
}

fn peek() Value {
    if (sp == 0) return Value.UNDEFINED;
    return stack[sp - 1];
}

fn boolVal(b: bool) Value {
    return if (b) Value.TRUE else Value.FALSE;
}

// ── Value Operations ──

// Large scratch for string concatenation. BotGuard concatenates its padding
// with the full VM payload, which can be hundreds of KB.
var concat_buf: [1024 * 1024]u8 = undefined;

pub var dbg_fh_captured: bool = false;
pub var dbg_fh_l6_tag: u8 = 255;
pub var dbg_fh_l6_obj: u32 = 0xFFFFFFFF;
pub var dbg_fh_func: u16 = 0xFFFF;
pub var dbg_fh_l6_num: f64 = -987654.0;
pub var dbg_fh_caller_func: u16 = 0xFFFF;
pub var dbg_fh_caller_ip: u32 = 0xFFFFFFFF;
pub var dbg_fh_l3_tag: u8 = 255;
pub var dbg_fh_l4_num: f64 = -987654.0;
pub fn dbgFhL6Tag() u8 { return dbg_fh_l6_tag; }
pub fn dbgFhL6Obj() u32 { return dbg_fh_l6_obj; }
pub fn dbgFhFunc() u16 { return dbg_fh_func; }
pub fn dbgFhL6Num() f64 { return dbg_fh_l6_num; }
pub fn dbgFhCallerFunc() u16 { return dbg_fh_caller_func; }
pub fn dbgFhCallerIp() u32 { return dbg_fh_caller_ip; }
pub fn dbgFhL3Tag() u8 { return dbg_fh_l3_tag; }
pub fn dbgFhL4Num() f64 { return dbg_fh_l4_num; }
pub var dbg_aRread_watch: bool = false;
pub var dbg_aRread_done: bool = false;
pub var dbg_aRread_name: u32 = 0;
pub var dbg_aRread_recv: u32 = 0xFFFFFFFF;
pub var dbg_aRread_own: u8 = 0;
pub var dbg_aRread_restag: u8 = 255;
pub var dbg_aRread_func: u16 = 0xFFFF;
pub var dbg_aRread_chain: [6]u32 = [_]u32{0xFFFFFFFF} ** 6;
pub var dbg_aRread_chain_n: u8 = 0;
pub var dbg_aRread_own_level: u8 = 255;
pub fn dbgARReadEnable(name_idx: u32) void { dbg_aRread_watch = true; dbg_aRread_done = false; dbg_aRread_name = name_idx; }
pub fn dbgARReadRecv() u32 { return dbg_aRread_recv; }
pub fn dbgARReadOwn() u8 { return dbg_aRread_own; }
pub fn dbgARReadResTag() u8 { return dbg_aRread_restag; }
pub fn dbgARReadFunc() u16 { return dbg_aRread_func; }
pub fn dbgARReadChainN() u8 { return dbg_aRread_chain_n; }
pub fn dbgARReadChain(i: usize) u32 { return if (i < 6) dbg_aRread_chain[i] else 0xFFFFFFFF; }
pub fn dbgARReadOwnLevel() u8 { return dbg_aRread_own_level; }
// ── `.H` read watch (for `r.H` in FH-site-2 closure func 157).
pub var dbg_hread_watch: bool = false;
pub var dbg_hread_done: bool = false;
pub var dbg_hread_name: u32 = 0;
pub var dbg_hread_func_filter: u16 = 0xFFFF;
pub var dbg_hread_recv_tag: u8 = 255;
pub var dbg_hread_recv_obj: u32 = 0xFFFFFFFF;
pub var dbg_hread_recv_num: f64 = -987654.0;
pub var dbg_hread_res_tag: u8 = 255;
pub var dbg_hread_res_num: f64 = -987654.0;
pub var dbg_hread_res_obj: u32 = 0xFFFFFFFF;
pub var dbg_hread_func: u16 = 0xFFFF;
pub var dbg_hread_total: u32 = 0;
pub fn dbgHReadEnable(name_idx: u32, func_filter: u16) void { dbg_hread_watch = true; dbg_hread_done = false; dbg_hread_name = name_idx; dbg_hread_func_filter = func_filter; }
pub fn dbgHReadFunc() u16 { return dbg_hread_func; }
pub fn dbgHReadTotal() u32 { return dbg_hread_total; }
pub var dbg_hread_good: u32 = 0;
pub var dbg_hread_bad: u32 = 0;
pub var dbg_hread_bad_at: u32 = 0;
pub var dbg_hread_bad_hasown: u8 = 255;
pub var dbg_hread_bad_getter: u8 = 255;
pub var dbg_hread_bad_objtype: u8 = 255;
pub var dbg_hread_bad_propcount: u16 = 0;
pub var dbg_hread_bad_arraylen: u32 = 0;
pub var dbg_hread_bad_dupH: u32 = 0;
pub fn dbgHReadBadHasOwn() u8 { return dbg_hread_bad_hasown; }
pub fn dbgHReadBadGetter() u8 { return dbg_hread_bad_getter; }
pub fn dbgHReadBadObjType() u8 { return dbg_hread_bad_objtype; }
pub fn dbgHReadBadPropCount() u16 { return dbg_hread_bad_propcount; }
pub fn dbgHReadBadArrayLen() u32 { return dbg_hread_bad_arraylen; }
pub fn dbgHReadBadDupH() u32 { return dbg_hread_bad_dupH; }
pub var dbg_hread_first_recv: u32 = 0xFFFFFFFF;
pub var dbg_hread_first_tag: u8 = 255;
pub var dbg_hread_first_res: u32 = 0xFFFFFFFF;
pub fn dbgHReadFirstRecv() u32 { return dbg_hread_first_recv; }
pub fn dbgHReadFirstTag() u8 { return dbg_hread_first_tag; }
pub fn dbgHReadFirstRes() u32 { return dbg_hread_first_res; }
pub fn dbgHReadGood() u32 { return dbg_hread_good; }
pub fn dbgHReadBad() u32 { return dbg_hread_bad; }
pub fn dbgHReadBadAt() u32 { return dbg_hread_bad_at; }
pub fn dbgHReadRecvTag() u8 { return dbg_hread_recv_tag; }
pub fn dbgHReadRecvObj() u32 { return dbg_hread_recv_obj; }
pub fn dbgHReadRecvNum() f64 { return dbg_hread_recv_num; }
pub fn dbgHReadResTag() u8 { return dbg_hread_res_tag; }
pub fn dbgHReadResNum() f64 { return dbg_hread_res_num; }
pub fn dbgHReadResObj() u32 { return dbg_hread_res_obj; }
pub var dbg_objfnwrite_done: bool = false;
pub var dbg_objfnwrite_reg: i32 = -1;
pub var dbg_objfnwrite_func: u16 = 0xFFFF;
pub var dbg_objfnwrite_ip: u32 = 0;
pub fn dbgObjFnWriteReg() i32 { return dbg_objfnwrite_reg; }
pub fn dbgObjFnWriteFunc() u16 { return dbg_objfnwrite_func; }
pub fn dbgObjFnWriteIp() u32 { return dbg_objfnwrite_ip; }
pub var dbg_fnts_done: bool = false;
pub var dbg_fnts_recv_tag: u8 = 255;
pub var dbg_fnts_calls: u32 = 0;
pub fn dbgFntsRecvTag() u8 { return dbg_fnts_recv_tag; }
pub fn dbgFntsCalls() u32 { return dbg_fnts_calls; }
pub var dbg_ppconcat_watch: bool = false;
pub var dbg_ppconcat_done: bool = false;
pub var dbg_ppconcat_btag: u8 = 255;
pub var dbg_ppconcat_bfunc: u16 = 0xFFFF;
pub var dbg_ppconcat_bstr: [256]u8 = undefined;
pub var dbg_ppconcat_bstr_len: usize = 0;
pub fn dbgPpConcatEnable() void { dbg_ppconcat_watch = true; dbg_ppconcat_done = false; }
pub fn dbgPpConcatBTag() u8 { return dbg_ppconcat_btag; }
pub fn dbgPpConcatBFunc() u16 { return dbg_ppconcat_bfunc; }
pub fn dbgPpConcatBStr() []const u8 { return dbg_ppconcat_bstr[0..dbg_ppconcat_bstr_len]; }
fn addValues(left: Value, right: Value) Value {
    const a = if (left.tag == .object or left.tag == .array or left.tag == .function) objectPrimitive(left) else left;
    const b = if (right.tag == .object or right.tag == .array or right.tag == .function) objectPrimitive(right) else right;
    // String concatenation if either operand is a string.
    if (a.tag == .string or b.tag == .string) {
        // DIAGNOSTIC: capture the operand tags when `a` is the string "PP=" (the
        // self-eval `"PP="+fn` concat) to see what `b` (the function/source) is.
        if (dbg_ppconcat_watch and !dbg_ppconcat_done and a.tag == .string) {
            const at = values.getString(a.data.str_idx);
            if (at.len == 3 and at[0] == 'P' and at[1] == 'P' and at[2] == '=') {
                dbg_ppconcat_done = true;
                dbg_ppconcat_btag = @intFromEnum(b.tag);
                dbg_ppconcat_bfunc = if (b.tag == .function) objects.closureFuncId(b.data.obj_idx) else 0xFFFF;
                if (b.tag == .string) { const bs = values.getString(b.data.str_idx); const k = @min(bs.len, dbg_ppconcat_bstr.len); @memcpy(dbg_ppconcat_bstr[0..k], bs[0..k]); dbg_ppconcat_bstr_len = k; }
            }
        }
        const a_text = values.getString(valueToStringIdx(a));
        const b_text = values.getString(valueToStringIdx(b));
        var o: usize = 0;
        const alen = @min(a_text.len, concat_buf.len);
        @memcpy(concat_buf[0..alen], a_text[0..alen]);
        o = alen;
        if (b_text.len > 0 and o < concat_buf.len) {
            const blen = @min(b_text.len, concat_buf.len - o);
            @memcpy(concat_buf[o .. o + blen], b_text[0..blen]);
            o += blen;
        }
        return Value.string(values.internString(concat_buf[0..o]));
    }
    return Value.number(a.toNumber() + b.toNumber());
}

fn valueToStringIdx(v: Value) u32 {
    return switch (v.tag) {
        .string => v.data.str_idx,
        .number => blk: {
            var buf: [32]u8 = undefined;
            const len = formatNumber(v.data.number, &buf);
            break :blk values.internString(buf[0..len]);
        },
        .boolean => if (v.data.boolean != 0) values.internString("true") else values.internString("false"),
        .null_val => values.internString("null"),
        .undefined => values.internString("undefined"),
        .function => blk: {
            // JS `""+fn` / String(fn) returns the function's SOURCE TEXT (BotGuard
            // self-rehydrates functions via `eval("NAME="+fn)` / createScript(fn)).
            const fid = objects.closureFuncId(v.data.obj_idx);
            if (fid != 0xFFFF) {
                const src = compiler.funcSourceText(fid);
                if (src.len > 0 and (src[0] == 'f' or src[0] == '(' or src[0] == 'a')) break :blk values.internString(src);
            }
            break :blk builtins.nativeFunctionSource(v);
        },
        .object, .array => objectToStringIdx(v),
        else => values.internString("[object Object]"),
    };
}

/// Coerce an object/array to its string form for concatenation. Invokes the
/// object's `toString` (found via the prototype chain) so Error objects yield
/// "name: message" and arrays yield their joined elements — matching JS `""+x`.
fn objectToStringIdx(v: Value) u32 {
    const oi: u32 = v.data.obj_idx;
    // Arrays: join elements with "," (JS Array.prototype.toString).
    if (objects.objTypeOf(oi) == .array) {
        const n = objects.arrayLength(oi);
        var o: usize = 0;
        var i: u32 = 0;
        while (i < n and o < concat_buf.len) : (i += 1) {
            if (i > 0) { concat_buf[o] = ','; o += 1; }
            const el = objects.getArrayElement(oi, i);
            const s = if (el.tag == .undefined or el.tag == .null_val) "" else values.getString(valueToStringIdx(el));
            const sl = @min(s.len, concat_buf.len - o);
            @memcpy(concat_buf[o .. o + sl], s[0..sl]);
            o += sl;
        }
        return values.internString(concat_buf[0..o]);
    }
    // Objects: call toString() if present on the prototype chain.
    const ts = getPropFromValue(v, values.internString("toString"));
    if (ts.tag == .function) {
        const fobj: u32 = ts.data.func_idx;
        const fid = objects.getObject(fobj).func_id;
        // Native toString (Error/Object): call with the receiver as args[0].
        if (fid >= 0xF000) {
            var a: [1]Value = .{v};
            const r = builtins.callNative(fid, a[0..1], 1);
            if (r.tag == .string) return r.data.str_idx;
        } else {
            // User-defined toString: run it synchronously with this=v.
            const r = callValueSync(ts, v, Value.UNDEFINED, Value.UNDEFINED, Value.UNDEFINED, 0);
            if (r.tag == .string) return r.data.str_idx;
            if (r.tag != .object and r.tag != .array) return valueToStringIdx(r);
        }
    }
    return values.internString("[object Object]");
}

fn formatNumber(n: f64, buf: *[32]u8) usize { return values.numberToString(n, buf); }

fn strictEq(a: Value, b: Value) bool {
    if (a.tag != b.tag) return false;
    return switch (a.tag) {
        .undefined, .null_val => true,
        .boolean => a.data.boolean == b.data.boolean,
        .number => a.data.number == b.data.number,
        .string => a.data.str_idx == b.data.str_idx,
        .object, .array, .function => a.data.obj_idx == b.data.obj_idx,
        else => false,
    };
}

fn abstractEq(a: Value, b: Value) bool {
    const a_object = a.tag == .object or a.tag == .array or a.tag == .function;
    const b_object = b.tag == .object or b.tag == .array or b.tag == .function;
    if (a_object and b_object) return a.data.obj_idx == b.data.obj_idx;
    if (a.tag == b.tag) return strictEq(a, b);
    // null and undefined are loosely equal to EACH OTHER and to NOTHING else.
    // They must never coerce to a number — `null == false`, `null == 0`,
    // `undefined == ''` are all FALSE. BotGuard's `while(null!=false)` (an
    // intentional `while(true)`) depends on `null != false` being true; the old
    // numeric fall-through made it false, corrupting loop control flow.
    if (a.tag == .null_val or a.tag == .undefined or b.tag == .null_val or b.tag == .undefined) {
        return (a.tag == .null_val or a.tag == .undefined) and (b.tag == .null_val or b.tag == .undefined);
    }
    if (a.tag == .boolean) return abstractEq(Value.number(a.toNumber()), b);
    if (b.tag == .boolean) return abstractEq(a, Value.number(b.toNumber()));
    if (a_object) return abstractEq(objectPrimitive(a), b);
    if (b_object) return abstractEq(a, objectPrimitive(b));
    return a.toNumber() == b.toNumber();
}

const RelationalOrder = enum { less, equal, greater, unordered };

fn relationalOrder(left: Value, right: Value) RelationalOrder {
    // ToPrimitive runs left-to-right for all four operators. Two strings use
    // lexical ordering; mixed primitive types use numeric conversion. NaN
    // is unordered, so <= and >= must not be implemented as negated < or >.
    const a = if (left.tag == .object or left.tag == .array or left.tag == .function) objectPrimitiveWithHint(left, false) else left;
    if (had_error) return .unordered;
    const b = if (right.tag == .object or right.tag == .array or right.tag == .function) objectPrimitiveWithHint(right, false) else right;
    if (had_error) return .unordered;
    if (a.tag == .string and b.tag == .string) {
        const x = values.getString(a.data.str_idx);
        const y = values.getString(b.data.str_idx);
        for (0..@min(x.len, y.len)) |i| {
            if (x[i] < y[i]) return .less;
            if (x[i] > y[i]) return .greater;
        }
        return if (x.len < y.len) .less else if (x.len > y.len) .greater else .equal;
    }
    const x = a.toNumber();
    const y = b.toNumber();
    if (x != x or y != y) return .unordered;
    return if (x < y) .less else if (x > y) .greater else .equal;
}

fn objectPrimitive(value: Value) Value {
    // Date's default hint is string. Numeric operations still explicitly
    // request number, while addition and loose equality use the default hint.
    return objectPrimitiveWithHint(value, objects.objTypeOf(value.data.obj_idx) == .date);
}

fn objectPrimitiveWithHint(value: Value, prefer_string: bool) Value {
    if (callbackAborted()) return Value.UNDEFINED;
    // Calling through the VM preserves receiver binding and user side effects.
    const names = if (prefer_string) [_][]const u8{ "toString", "valueOf" } else [_][]const u8{ "valueOf", "toString" };
    for (names) |name| {
        const method = getPropFromValue(value, values.internString(name));
        if (method.tag != .function) continue;
        const result = callValueSync(method, value, Value.UNDEFINED, Value.UNDEFINED, Value.UNDEFINED, 0);
        if (callbackAborted()) return Value.UNDEFINED;
        if (result.tag != .object and result.tag != .array and result.tag != .function) return result;
    }
    throwTypeErrorMsg("Cannot convert object to primitive value");
    return Value.UNDEFINED;
}

fn stringObjectPrimitive(value: Value) u32 {
    if (callbackAborted()) return values.internString("");
    for ([_][]const u8{ "toString", "valueOf" }) |name| {
        const method = getPropFromValue(value, values.internString(name));
        if (method.tag != .function) continue;
        const result = callValueSync(method, value, Value.UNDEFINED, Value.UNDEFINED, Value.UNDEFINED, 0);
        if (callbackAborted()) return values.internString("");
        if (result.tag != .object and result.tag != .array and result.tag != .function) return valueToStringIdx(result);
    }
    throwTypeErrorMsg("Cannot convert object to primitive value");
    return values.internString("");
}

fn numericObjectPrimitive(index: u32) f64 {
    if (callbackAborted()) return @bitCast(@as(u64, 0x7FF8000000000000));
    const value = if (objects.objTypeOf(index) == .function) Value.function(index) else Value.object(index);
    return objectPrimitiveWithHint(value, false).toNumber();
}

/// `a instanceof B`: true if B.prototype is in a's [[Prototype]] chain.
fn instanceOf(a: Value, b: Value) bool {
    if (b.tag != .function) return false;
    if (a.tag != .object and a.tag != .array and a.tag != .function) return false;
    // B.prototype (lazily created for user functions; for built-in Array/Object
    // constructors this is the corresponding shared proto object).
    const bproto = getPropFromValue(b, values.internString("prototype"));
    if (bproto.tag != .object and bproto.tag != .array and bproto.tag != .function) {
        // Built-in constructors (Array, Object, ...) whose `.prototype` maps to
        // a shared proto: match by the constructor's well-known proto.
        return instanceOfBuiltin(a, b);
    }
    const target_proto: u32 = bproto.data.obj_idx;
    var cur: u32 = a.data.obj_idx;
    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        const p = objects.getObjectPrototypeIdx(cur);
        if (p == objects.NULL_OBJ) break;
        if (p == target_proto) return true;
        cur = p;
    }
    return false;
}

/// instanceof against a built-in constructor identified by name (Array/Object/
/// Function), matching the value's kind. Covers `x instanceof Array` etc. where
/// the constructor's `.prototype` isn't a distinct own object.
fn instanceOfBuiltin(a: Value, b: Value) bool {
    const bobj: u32 = b.data.func_idx;
    const name_idx = objects.getObject(bobj).func_id;
    _ = name_idx;
    const bname = builtinConstructorName(b);
    if (eql(bname, "Array")) return a.tag == .array or (a.tag == .object and objects.getObject(@intCast(a.data.obj_idx)).obj_type == .array);
    if (eql(bname, "Object")) return a.tag == .object or a.tag == .array or a.tag == .function;
    if (eql(bname, "Function")) return a.tag == .function;
    return false;
}

/// Best-effort name of a built-in constructor value (from the global object).
fn builtinConstructorName(b: Value) []const u8 {
    if (b.tag != .function) return "";
    const bobj: u32 = b.data.func_idx;
    // Match against well-known global constructors.
    const arr_ctor = objects.getProperty(global_obj, values.internString("Array"));
    if (arr_ctor.tag == .function and arr_ctor.data.func_idx == bobj) return "Array";
    const obj_ctor = objects.getProperty(global_obj, values.internString("Object"));
    if (obj_ctor.tag == .function and obj_ctor.data.func_idx == bobj) return "Object";
    const fn_ctor = objects.getProperty(global_obj, values.internString("Function"));
    if (fn_ctor.tag == .function and fn_ctor.data.func_idx == bobj) return "Function";
    return "";
}

fn typeofValue(v: Value) Value {
    const str = switch (v.tag) {
        .undefined => "undefined",
        .null_val => "object", // typeof null === "object"
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .function => "function",
        .object, .array => "object",
        else => "undefined",
    };
    return Value.string(values.internString(str));
}

fn getPropFromValue(obj_val: Value, name_idx: u32) Value {
    if (callbackAborted()) return Value.UNDEFINED;
    // Diagnostic: reading `.prototype` (or any prop) off undefined/null is the
    // usual precursor to a not-callable. Capture the first such occurrence with
    // the receiver-producing lookup name so we can locate the divergence.
    if ((obj_val.tag == .undefined or obj_val.tag == .null_val) and
        eql(values.getString(name_idx), "prototype"))
    {
        dbg_undef_prop_captured = true;
        dbg_undef_prop_count += 1;
        dbg_undef_prop_name = name_idx;
        dbg_undef_prop_recv_name = prev_lookup_name;
        if (frame_count > 0) { dbg_undef_prop_func = frames[frame_count - 1].func_id; dbg_undef_prop_ip = frames[frame_count - 1].ip; }
    }
    if (obj_val.tag == .function) {
        const name = values.getString(name_idx);
        // Trace: log the sequence of `.apply` reads on FUNCTIONS (E is a fn) so
        // we can compare our VM's apply-probe sequence to jsdom's.
        if (dbg_mm_probe and eql(name, "apply") and dbg_applyseq_n < 32) {
            dbg_applyseq_tag[dbg_applyseq_n] = 6; // function
            dbg_applyseq_n += 1;
        }
        const fobj: u32 = obj_val.data.obj_idx;
        const fid = objects.closureFuncId(fobj);
        if (!objects.hasOwnProperty(fobj, name_idx) and fid < builtins.NATIVE_BASE) {
            const desc = compiler.getFunction(fid);
            if (eql(name, "length")) return Value.number(@floatFromInt(desc.param_count));
            if (eql(name, "name")) return Value.string(values.internString(if (desc.name_const == 0xFFFF) "" else compiler.constStr(desc.name_const)));
        }
        // Every (non-arrow) function has an own `.prototype` object in JS,
        // created lazily on first access. BotGuard builds class hierarchies via
        // `f.prototype.method = ...` and `new f()`, so this must exist or the
        // whole setup collapses (dY.prototype would be undefined → tamper throw).
        if (eql(name, "prototype")) {
            if (fid == builtins.N_FUNCTION_PROTO or (fid < builtins.NATIVE_BASE and compiler.getFunction(fid).is_arrow)) return Value.UNDEFINED;
            if (objects.hasOwnProperty(fobj, name_idx)) {
                return objects.getProperty(fobj, name_idx);
            }
            if (fid >= builtins.NATIVE_BASE and !builtins.nativeHasPrototype(fid)) return Value.UNDEFINED;
            if (fid < builtins.NATIVE_BASE and compiler.getFunction(fid).is_async and !compiler.getFunction(fid).is_generator) return Value.UNDEFINED;
            const proto = objects.createObject();
            // proto.constructor = the function (standard JS)
            objects.setProperty(proto, values.internString("constructor"), obj_val);
            objects.setEnumerable(proto, values.internString("constructor"), false);
            const pv = Value.object(proto);
            objects.setProperty(fobj, name_idx, pv);
            objects.setEnumerable(fobj, name_idx, false);
            return pv;
        }
        // Any other property looked up on a function object.
        return objects.getProperty(fobj, name_idx);
    }
    if (obj_val.tag == .object or obj_val.tag == .array) {
        const oi: u32 = obj_val.data.obj_idx;
        // Arrays expose a dynamic `length` (stored as array_len, not a property).
        const otype = objects.getObject(oi).obj_type;
        if (otype == .array) {
            const name = values.getString(name_idx);
            if (eql(name, "length")) {
                return Value.number(@floatFromInt(objects.arrayLength(oi)));
            }
        }
        // Accessor (getter) property: invoke the getter with this=obj_val.
        var getter: Value = Value.UNDEFINED;
        if (objects.getPropertyGetter(oi, name_idx, &getter) and getter.tag == .function) {
            return callValueSync(getter, obj_val, Value.UNDEFINED, Value.UNDEFINED, Value.UNDEFINED, 0);
        }
        const gp = objects.getProperty(oi, name_idx);
        // FINGERPRINT PROBE: record property reads that MISS on the env objects
        // (navigator/document/window/screen/location/canvas contexts). A miss
        // means BotGuard probed a browser feature our env doesn't implement — a
        // fingerprint leak. Only records when dbg_fp_probe is armed.
        if (dbg_fp_probe and gp.tag == .undefined and objects.dbgIsEnvObject(oi)) {
            recordFpMiss(oi, name_idx);
        }
        // STACK-READ PROBE: the inner VM reads `err.stack` only at its type-144
        // error-accumulator, so each such read = one error folded into the
        // response payload (the null-token cause). Capture the error's message.
        if (dbg_mm_probe and eql(values.getString(name_idx), "stack")) {
            const msgv = objects.getProperty(oi, values.internString("message"));
            if (msgv.tag == .string) {
                dbg_stack_reads += 1;
                if (dbg_stack_msg_n < dbg_stack_msgs.len) {
                    const ms = values.getString(msgv.data.str_idx);
                    const k = @min(ms.len, 96);
                    @memcpy(dbg_stack_msgs[dbg_stack_msg_n][0..k], ms[0..k]);
                    dbg_stack_msg_len[dbg_stack_msg_n] = k;
                    dbg_stack_msg_n += 1;
                }
            }
        }
        // METHOD-MISS PROBE: a method-name property that resolves to a
        // non-function is the direct cause of "X.method is not a function"
        // throws that BotGuard packs into the (payload-inflating) transcript.
        // Record the RECEIVER's obj_type (encoded in the tag slot: +100 = the
        // receiver was itself a function-object accessed as .object) so we can
        // tell if a callable is mis-tagged.
        if (dbg_mm_probe and gp.tag != .function) {
            const nm = values.getString(name_idx);
            if (isProbeMethodName(nm)) {
                const rt: u8 = @intFromEnum(objects.getObject(oi).obj_type);
                recordMethodMiss(name_idx, 100 + rt, objects.dbgIsEnvObject(oi));
                // For `.apply`/`.call` misses on an array receiver, capture the
                // array's length + first two element tags to identify it.
                if (eql(nm, "apply") and dbg_applyseq_n < 32) {
                    dbg_applyseq_tag[dbg_applyseq_n] = @intFromEnum(objects.getObject(oi).obj_type) + 100;
                    dbg_applyseq_n += 1;
                }
                if ((eql(nm, "apply") or eql(nm, "call")) and objects.getObject(oi).obj_type == .array and dbg_applyarr_n < 8) {
                    const al = objects.arrayLength(oi);
                    dbg_applyarr_len[dbg_applyarr_n] = al;
                    dbg_applyarr_e0[dbg_applyarr_n] = if (al > 0) @intFromEnum(objects.getArrayElement(oi, 0).tag) else 255;
                    dbg_applyarr_e1[dbg_applyarr_n] = if (al > 1) @intFromEnum(objects.getArrayElement(oi, 1).tag) else 255;
                    // If element[0] is an object, record its obj_type + first 3 own prop names.
                    if (al > 0) {
                        const e0 = objects.getArrayElement(oi, 0);
                        if (e0.tag == .object or e0.tag == .array or e0.tag == .function) {
                            const e0i: u32 = e0.data.obj_idx;
                            dbg_applyarr_e0type[dbg_applyarr_n] = @intFromEnum(objects.getObject(e0i).obj_type);
                            var pk: usize = 0;
                            while (pk < 3) : (pk += 1) {
                                const pn = objects.ownPropNameAt(e0i, @intCast(pk));
                                dbg_applyarr_e0prop[dbg_applyarr_n][pk] = pn;
                            }
                        }
                    }
                    dbg_applyarr_n += 1;
                }
            }
        }
        return gp;
    }
    if (obj_val.tag == .string) {
        // String property access (length, prototype methods)
        const name = values.getString(name_idx);
        if (eql(name, "length")) {
            return Value.number(@floatFromInt(values.getStringUnitLength(obj_val.data.str_idx)));
        }
        if (objects.arrayIndexName(name)) |index| {
            if (index < values.getStringUnitLength(obj_val.data.str_idx)) return Value.string(values.getStringUnit(obj_val.data.str_idx, index));
            return Value.UNDEFINED;
        }
        // Check string prototype
        return objects.getProperty(objects.getStringProto(), name_idx);
    }
    // Primitive number/boolean property access goes through their prototype
    // chain (e.g. `(0).constructor` === Number, `(1).toString`). Without this
    // `.constructor` on a primitive returns undefined and BotGuard's type
    // detection diverges.
    if (obj_val.tag == .number) {
        return objects.getProperty(objects.getNumberProto(), name_idx);
    }
    if (obj_val.tag == .boolean) {
        return objects.getProperty(objects.getBooleanProto(), name_idx);
    }
    return Value.UNDEFINED;
}

fn setPropOnValue(obj_val: Value, name_idx: u32, val: Value) void {
    if (callbackAborted()) return;
    if (obj_val.tag == .undefined or obj_val.tag == .null_val) {
        throwCannotSetProp(obj_val.tag == .null_val, values.getString(name_idx));
        return;
    }
    if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function) {
        const oi: u32 = obj_val.data.obj_idx;
        // Assigning `arr.length = N` on an array resizes it (JS: truncates when
        // N < current length, grows with holes when larger). BotGuard's register
        // machine sets register-array lengths explicitly (`X.length = w.shift()`),
        // so this MUST update array_len — otherwise stale elements linger and the
        // register cipher / `.concat` operate on the wrong length.
        if (objects.objTypeOf(oi) == .array and eql(values.getString(name_idx), "length")) {
            const n = val.toNumber();
            if (n == n and n >= 0) { // finite, non-negative
                objects.arraySetLength(oi, @intFromFloat(@floor(n)));
                return;
            }
        }
        setPropRespectingAccessors(oi, name_idx, val, obj_val);
    }
}

/// Store `obj[name] = val` honouring JS [[Set]] semantics against the prototype
/// chain: an inherited getter-only accessor makes the assignment a silent no-op
/// (non-strict), and a setter is invoked instead of creating a data property.
/// BotGuard's register objects are `Object.create(proto-with-'create'-getter)`
/// then `obj[N.R] = fn` (N.R === "create") — the assignment MUST be ignored so
/// `obj.create` keeps running the inherited getter (which returns the computed
/// register value). Creating an own data property instead corrupts every
/// register read and stalls the interpreter. This path is shared by set_prop
/// and computed string-key set_elem.
fn setPropRespectingAccessors(oi: u32, name_idx: u32, val: Value, receiver: Value) void {
    if (callbackAborted()) return;
    if (eql(values.getString(name_idx), "H") and val.tag == .number and dbg_hnum_func == 0xFFFF and frame_count > 0) { dbg_hnum_func = frames[frame_count-1].func_id; dbg_hnum_value = val.data.number; dbg_hnum_caller = if (frame_count > 1) frames[frame_count-2].func_id else 0xFFFF; }
    var setter: Value = Value.UNDEFINED;
    switch (objects.resolveSet(oi, name_idx, &setter)) {
        .data => objects.setProperty(oi, name_idx, val),
        .ignore => {}, // getter-only accessor shadows: silently ignore
        .setter => {
            if (setter.tag == .function) {
                _ = callValueSync(setter, receiver, val, Value.UNDEFINED, Value.UNDEFINED, 1);
            } // else: no callable setter -> ignore
        },
    }
}

/// Format a small unsigned integer as decimal digits into buf; returns length.
fn idxToStr(n: u32, buf: *[16]u8) usize {
    if (n == 0) { buf[0] = '0'; return 1; }
    var digits: [10]u8 = undefined;
    var d: usize = 0;
    var v = n;
    while (v > 0) : (d += 1) { digits[d] = @intCast((v % 10) + '0'); v /= 10; }
    var i: usize = 0;
    while (i < d) : (i += 1) buf[i] = digits[d - 1 - i];
    return d;
}

/// Parse a canonical array-index string ("0","1",...,"4294967294") to u32.
/// Returns null for non-index strings (named properties, leading zeros, etc.).
fn parseArrayIndex(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 10) return null;
    if (s[0] == '0' and s.len > 1) return null; // no leading zeros ("01" is a named prop)
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 4294967294) return null;
    }
    return @intCast(v);
}

/// Safe float -> array index. NaN/negative/huge/Infinity clamp to 0/cap.
fn safeIdx(n: f64) u32 {
    if (n != n or n <= 0) return 0;
    if (n >= 4294967295.0) return 0;
    return @intFromFloat(@floor(n));
}

/// True if a JS number is a canonical array index: a non-negative integer in
/// [0, 2^32-1). NaN, Infinity, negatives, and fractionals are NOT indices — in
/// JS `a[NaN]`/`a[1.5]`/`a[-1]` are NAMED properties (a["NaN"], a["1.5"], ...),
/// which are absent on a plain array -> undefined. Treating NaN as index 0
/// (the old `safeIdx` behaviour) corrupted BotGuard's register cipher (a NaN
/// register value read back as element 0), causing nondeterministic infinite
/// loops in the interpreter.
pub var dbg_nan_idx_captured: bool = false;
pub var dbg_nan_idx_func: u16 = 0xFFFF;
pub var dbg_nan_idx_ip: u32 = 0;
pub fn dbgNanIdx() [2]u32 { return .{ dbg_nan_idx_func, dbg_nan_idx_ip }; }
pub var dbg_undefglobal_captured: bool = false;
pub var dbg_undefglobal_name: [48]u8 = undefined;
pub var dbg_undefglobal_name_len: usize = 0;
pub var dbg_undefglobal_func: u16 = 0xFFFF;
pub var dbg_undefglobal_ip: u32 = 0;
// Track def_global / ReferenceError for a specific 1-char global name (e.g. 'w')
// to determine whether it is ever defined and whether the RefError precedes its def.
pub var dbg_wtrack_char: u8 = 0;
pub var dbg_w_defglobal_count: u32 = 0;
pub var dbg_w_last_defglobal_func: u16 = 0xFFFF;
pub var dbg_w_refError_count: u32 = 0;
pub var dbg_w_defglobal_at_referror: u32 = 0xFFFFFFFF;
pub fn dbgUndefGlobalName() []const u8 { return dbg_undefglobal_name[0..dbg_undefglobal_name_len]; }
pub var dbg_nan_op: [80]u8 = [_]u8{0} ** 80;
pub var dbg_nan_op_n: usize = 0;
pub fn dbgNanOpCount() usize { return dbg_nan_op_n; }
pub fn dbgNanOpName(i: usize) []const u8 { if (i >= dbg_nan_op_n) return ""; return @tagName(@as(Op, @enumFromInt(dbg_nan_op[i]))); }
fn numIsArrayIndex(n: f64) bool {
    if (n != n) return false; // NaN
    if (n < 0) return false;
    if (n >= 4294967295.0) return false;
    return @floor(n) == n; // integer-valued
}

fn getElemFromValue(obj_val: Value, key: Value) Value {
    // Numeric index on arrays/objects: direct element access — ONLY for a
    // canonical array index. Other numeric keys (NaN, fractional, negative)
    // are named properties.
    if ((obj_val.tag == .object or obj_val.tag == .array) and key.tag == .number) {
        // Canonical array-index numeric key: element access ONLY on real arrays.
        // On a PLAIN OBJECT a numeric key `o[3]` is the NAMED property "3" (JS
        // ToPropertyKey), NOT an array element — reading it via getArrayElement
        // returned undefined even though `o[3]=v` stored the named prop "3"
        // (setElemOnValue correctly checks objTypeOf==.array first). That
        // get/set asymmetry made EVERY numeric-keyed object read miss — which is
        // exactly how BotGuard's register banks are accessed (`x.Y[bankNum]`),
        // causing thousands of spurious register-void faults and a null token.
        const indexed_type = objects.objTypeOf(obj_val.data.obj_idx);
        if (numIsArrayIndex(key.data.number) and (indexed_type == .array or indexed_type == .typed_array)) {
            const idx: u32 = @intFromFloat(@floor(key.data.number));
            if (objects.hasArrayElement(obj_val.data.obj_idx, idx)) return objects.getArrayElement(obj_val.data.obj_idx, idx);
            return getPropFromValue(obj_val, builtins.keyToNameIdx(key));
        }
        // Numeric key on a plain object (or non-index numeric): named property.
        // (o[3] === o["3"], o[NaN] === o["NaN"].)
        if (key.data.number != key.data.number and !dbg_nan_idx_captured) { // NaN key
            dbg_nan_idx_captured = true;
            if (frame_count > 0) { dbg_nan_idx_func = frames[frame_count - 1].func_id; dbg_nan_idx_ip = frames[frame_count - 1].ip; }
            // Snapshot the recent opcode ring (oldest->newest) to see what
            // arithmetic produced the NaN index.
            dbg_nan_op_n = 0;
            const oc = @min(op_ring.len, op_ring_pos);
            var oj: usize = 0;
            while (oj < oc) : (oj += 1) {
                const oi = (op_ring_pos - oc + oj) % op_ring.len;
                dbg_nan_op[dbg_nan_op_n] = op_ring[oi];
                dbg_nan_op_n += 1;
            }
        }
        return getPropFromValue(obj_val, builtins.keyToNameIdx(key));
    }
    // Numeric index into a string: single-char access (canonical index only).
    if (obj_val.tag == .string and key.tag == .number) {
        if (!numIsArrayIndex(key.data.number)) return Value.UNDEFINED;
        const idx: usize = @intFromFloat(@floor(key.data.number));
        if (idx < values.getStringUnitLength(obj_val.data.str_idx)) {
            const ch_idx = values.getStringUnit(obj_val.data.str_idx, idx);
            return Value.string(ch_idx);
        }
        return Value.UNDEFINED;
    }
    // String key `X[k]` is identical to member access `X.k` — route through the
    // same resolver so functions get .call/.apply/.bind/.prototype and the
    // prototype chain (hasOwnProperty, etc.), objects get getters/length, and
    // strings get their prototype methods. Previously function receivers fell
    // through to UNDEFINED, breaking BotGuard's pervasive computed access.
    if (key.tag == .string) {
        // Array indexed by a NUMERIC-STRING key ("0","1",...) — e.g. from
        // `for (k in arr) arr[k]` — must read the element, not a named property.
        // BotGuard's interpreter (T state 54) iterates `for(E in A) ...A[E]...`
        // with string keys; treating them as named props returned undefined and
        // derailed the whole interpreter loop.
        if ((obj_val.tag == .array or obj_val.tag == .object) and
            (objects.objTypeOf(obj_val.data.obj_idx) == .array or objects.objTypeOf(obj_val.data.obj_idx) == .typed_array))
        {
            const ks = values.getString(key.data.str_idx);
            if (parseArrayIndex(ks)) |idx| {
                if (objects.hasArrayElement(obj_val.data.obj_idx, idx)) return objects.getArrayElement(obj_val.data.obj_idx, idx);
                return getPropFromValue(obj_val, key.data.str_idx);
            }
        }
        return getPropFromValue(obj_val, key.data.str_idx);
    }
    // Non-string, non-number key (array/object/bool/null/undefined): coerce to
    // a string property key (JS ToPropertyKey) and resolve. `o[[]]` -> `o[""]`.
    // Note: the empty-string key is valid (interns to a real index), so do NOT
    // guard against index 0.
    if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function or obj_val.tag == .string) {
        return getPropFromValue(obj_val, builtins.keyToNameIdx(key));
    }
    return Value.UNDEFINED;
}

fn setElemOnValue(obj_val: Value, key: Value, val: Value) void {
    if (callbackAborted()) return;
    if (obj_val.tag == .undefined or obj_val.tag == .null_val) {
        // PutValue fails before an object key's conversion. Key expression and
        // RHS have already run; do not invoke a key's toString on this path.
        const name = if (key.tag == .object or key.tag == .array or key.tag == .function) null else values.getString(builtins.keyToNameIdx(key));
        throwCannotSetProp(obj_val.tag == .null_val, name);
        return;
    }
    if (obj_val.tag != .object and obj_val.tag != .array and obj_val.tag != .function) return;
    const oi: u32 = obj_val.data.obj_idx;
    if (key.tag == .number) {
        if ((objects.objTypeOf(oi) == .array or objects.objTypeOf(oi) == .typed_array) and numIsArrayIndex(key.data.number)) {
            if (objects.isFrozen(oi)) return;
            const name = builtins.keyToNameIdx(key);
            if (objects.dbgFindPropNode(oi, name) != objects.NULL_PROP) { setPropRespectingAccessors(oi, name, val, obj_val); return; }
            objects.setArrayElement(oi, @intFromFloat(@floor(key.data.number)), val);
            return;
        }
        // Non-index numeric key (NaN/fractional/negative) -> named property.
        setPropRespectingAccessors(oi, builtins.keyToNameIdx(key), val, obj_val);
        return;
    }
    if (key.tag == .string) {
        // Numeric-string key on an array writes the element (mirror of getElem).
        if (objects.objTypeOf(oi) == .array or objects.objTypeOf(oi) == .typed_array) {
            const ks = values.getString(key.data.str_idx);
            if (parseArrayIndex(ks)) |idx| {
                if (objects.isFrozen(oi)) return;
                if (objects.dbgFindPropNode(oi, key.data.str_idx) != objects.NULL_PROP) { setPropRespectingAccessors(oi, key.data.str_idx, val, obj_val); return; }
                objects.setArrayElement(oi, idx, val);
                return;
            }
        }
        // Computed string-key set must honour prototype-chain accessors — the
        // register-object `obj[N.R]=fn` (N.R="create") relies on this.
        setPropOnValue(obj_val, key.data.str_idx, val);
        return;
    }
    // Non-string/number key (array/object/bool/null/undefined): coerce to a
    // string property key (JS ToPropertyKey). `o[[]]=v` -> `o[""]=v`. BotGuard's
    // interpreter uses `[]`-valued opcode markers as object keys — this MUST
    // store the coerced key (and getElemFromValue reads the same).
    setPropOnValue(obj_val, builtins.keyToNameIdx(key), val);
}

// ── Bit operation helpers ──

fn jsRemainder(a: f64, b: f64) f64 {
    const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    if (a != a or b != b or a == inf or a == -inf or b == 0)
        return @bitCast(@as(u64, 0x7FF8000000000000));
    if (a == 0 or b == inf or b == -inf) return a;
    return @rem(a, b);
}

// JS ToUint32: truncate toward zero, then take modulo 2^32. Handles NaN, ±0,
// ±Infinity, and out-of-range magnitudes without panicking on @intFromFloat.
fn toU32(v: Value) u32 {
    const n = v.toNumber();
    if (n != n) return 0; // NaN
    // Reject non-finite (Infinity): its integer part is undefined -> 0.
    const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    if (n == inf or n == -inf) return 0;
    // Truncate toward zero.
    var t = if (n < 0) @ceil(n) else @floor(n);
    // Reduce modulo 2^32 into [0, 2^32) using f64 (safe: |t| kept bounded).
    const two32 = 4294967296.0;
    t = @mod(t, two32);
    if (t < 0) t += two32;
    if (t >= two32) t = 0;
    return @intFromFloat(t);
}

fn toI32(v: Value) i32 {
    const u = toU32(v);
    // Reinterpret the low 32 bits as a signed value.
    return @bitCast(u);
}

fn toU5(v: Value) u5 {
    return @intCast(toU32(v) & 0x1F);
}

fn shlI32(a: i32, b: u5) i32 {
    return a << b;
}

fn shrI32(a: i32, b: u5) i32 {
    return a >> b;
}

fn ushrU32(a: u32, b: u5) u32 {
    return a >> b;
}

fn mathPow(base: f64, exp: f64) f64 {
    // Simple integer power for common cases
    if (exp == 0) return 1.0;
    if (exp == 1) return base;
    if (exp == 2) return base * base;
    if (exp == -1) return 1.0 / base;
    // General case via repeated multiplication (approximate)
    var result: f64 = 1.0;
    var e = if (exp < 0) -exp else exp;
    while (e >= 1.0) : (e -= 1.0) {
        result *= base;
    }
    return if (exp < 0) 1.0 / result else result;
}

// ── Bytecode reading ──

fn readU16(bc: []const u8, ip: *u32) u16 {
    if (ip.* + 1 >= bc.len) return 0;
    const lo: u16 = bc[ip.*];
    const hi: u16 = bc[ip.* + 1];
    ip.* += 2;
    return lo | (hi << 8);
}

/// Read a 32-bit little-endian control-flow operand (jump/loop/try targets).
fn readU32(bc: []const u8, ip: *u32) u32 {
    if (ip.* + 3 >= bc.len) return 0;
    const b0: u32 = bc[ip.*];
    const b1: u32 = bc[ip.* + 1];
    const b2: u32 = bc[ip.* + 2];
    const b3: u32 = bc[ip.* + 3];
    ip.* += 4;
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

fn constToValue(idx: u16) Value {
    const c = compiler.getConstant(idx);
    if (c.is_string) return Value.string(c.str_idx);
    return Value.number(c.num);
}

fn constToStringIdx(idx: u16) u32 {
    const c = compiler.getConstant(idx);
    if (c.is_string) return c.str_idx;
    // Number constant used as property name — format it
    var buf: [32]u8 = undefined;
    const len = formatNumber(c.num, &buf);
    return values.internString(buf[0..len]);
}

fn startsWith(a: []const u8, b: []const u8) bool {
    return a.len >= b.len and eql(a[0..b.len], b);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}
