// @zpm/youtube/botguard/jsvm/builtins — Built-in Functions
//
// Implements JavaScript standard library functions needed by BotGuard:
//   - Math.* (floor, ceil, round, abs, min, max, random, pow, log, sqrt)
//   - JSON.parse, JSON.stringify
//   - Array.prototype.* (push, pop, splice, slice, indexOf, map, forEach, filter,
//                         reduce, join, reverse, sort, concat, includes, find)
//   - String.prototype.* (charAt, charCodeAt, split, substring, slice, indexOf,
//                          replace, trim, toLowerCase, toUpperCase, includes,
//                          startsWith, endsWith, repeat, padStart, padEnd)
//   - String.fromCharCode
//   - parseInt, parseFloat, isNaN, isFinite
//   - encodeURIComponent, decodeURIComponent
//   - atob, btoa
//   - setTimeout (stub), setInterval (stub)
//   - console.log (debug only)
//
// Native functions use func_id >= 0xF000 to distinguish from user functions.

const values = @import("values.sig");
const objects = @import("objects.sig");
const compiler = @import("compiler.sig");
const regexp = @import("regexp.sig");
const Value = values.Value;
// The VM supplies synchronous JavaScript callback execution without a reverse
// import from native builtins into the interpreter.
pub var invoke_callback: ?*const fn (Value, Value, []const Value) Value = null;

// ── Debug print (console.log) ──
extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
fn dbgPrint(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(@bitCast(@as(i32, -11))), msg.ptr, @intCast(msg.len), null, null);
}
fn nConsoleLog(args: []const Value) Value {
    dbgPrint("[JSLOG] ");
    for (args, 0..) |a, i| {
        if (i > 0) dbgPrint(" ");
        switch (a.tag) {
            .string => dbgPrint(values.getString(a.data.str_idx)),
            .number => {
                var buf: [32]u8 = undefined;
                const f = a.data.number;
                const neg = f < 0;
                const iv: i64 = @intFromFloat(if (neg) -f else f);
                var v: u64 = @intCast(iv);
                var tmp: [24]u8 = undefined;
                var n: usize = 0;
                if (v == 0) { tmp[0] = '0'; n = 1; } else { while (v > 0) : (v /= 10) { tmp[n] = @intCast((v % 10) + '0'); n += 1; } }
                var p: usize = 0;
                if (neg) { buf[0] = '-'; p = 1; }
                var k: usize = 0;
                while (k < n) : (k += 1) { buf[p] = tmp[n - 1 - k]; p += 1; }
                dbgPrint(buf[0..p]);
            },
            .boolean => dbgPrint(if (a.data.boolean != 0) "true" else "false"),
            .undefined => dbgPrint("undefined"),
            .null_val => dbgPrint("null"),
            else => dbgPrint("[obj]"),
        }
    }
    dbgPrint("\n");
    return Value.UNDEFINED;
}

// ── Native Function IDs ──

pub const NATIVE_BASE: u16 = 0xF000;

// Math
pub const N_MATH_FLOOR: u16 = NATIVE_BASE + 0;
pub const N_MATH_CEIL: u16 = NATIVE_BASE + 1;
pub const N_MATH_ROUND: u16 = NATIVE_BASE + 2;
pub const N_MATH_ABS: u16 = NATIVE_BASE + 3;
pub const N_MATH_MIN: u16 = NATIVE_BASE + 4;
pub const N_MATH_MAX: u16 = NATIVE_BASE + 5;
pub const N_MATH_RANDOM: u16 = NATIVE_BASE + 6;
pub const N_MATH_POW: u16 = NATIVE_BASE + 7;
pub const N_MATH_LOG: u16 = NATIVE_BASE + 8;
pub const N_MATH_SQRT: u16 = NATIVE_BASE + 9;
pub const N_MATH_SIGN: u16 = NATIVE_BASE + 10;
pub const N_MATH_TRUNC: u16 = NATIVE_BASE + 11;
pub const N_MATH_CLZ32: u16 = NATIVE_BASE + 12;
pub const N_MATH_IMUL: u16 = NATIVE_BASE + 13;
pub const N_MATH_FROUND: u16 = NATIVE_BASE + 14;

// JSON
pub const N_JSON_PARSE: u16 = NATIVE_BASE + 20;
pub const N_JSON_STRINGIFY: u16 = NATIVE_BASE + 21;

// Global functions
pub const N_PARSE_INT: u16 = NATIVE_BASE + 30;
pub const N_PARSE_FLOAT: u16 = NATIVE_BASE + 31;
pub const N_IS_NAN: u16 = NATIVE_BASE + 32;
pub const N_IS_FINITE: u16 = NATIVE_BASE + 33;
pub const N_ENCODE_URI: u16 = NATIVE_BASE + 34;
pub const N_DECODE_URI: u16 = NATIVE_BASE + 35;
pub const N_ATOB: u16 = NATIVE_BASE + 36;
pub const N_BTOA: u16 = NATIVE_BASE + 37;
pub const N_SET_TIMEOUT: u16 = NATIVE_BASE + 38;
pub const N_SET_INTERVAL: u16 = NATIVE_BASE + 39;
pub const N_CLEAR_TIMEOUT: u16 = NATIVE_BASE + 40;
pub const N_CONSOLE_LOG: u16 = NATIVE_BASE + 41;

// String
pub const N_STR_FROM_CHARCODE: u16 = NATIVE_BASE + 50;
pub const N_STR_CHAR_AT: u16 = NATIVE_BASE + 51;
pub const N_STR_CHAR_CODE_AT: u16 = NATIVE_BASE + 52;
pub const N_STR_INDEX_OF: u16 = NATIVE_BASE + 53;
pub const N_STR_SLICE: u16 = NATIVE_BASE + 54;
pub const N_STR_SUBSTRING: u16 = NATIVE_BASE + 55;
pub const N_STR_SPLIT: u16 = NATIVE_BASE + 56;
pub const N_STR_REPLACE: u16 = NATIVE_BASE + 57;
pub const N_STR_TRIM: u16 = NATIVE_BASE + 58;
pub const N_STR_TO_LOWER: u16 = NATIVE_BASE + 59;
pub const N_STR_TO_UPPER: u16 = NATIVE_BASE + 60;
pub const N_STR_INCLUDES: u16 = NATIVE_BASE + 61;
pub const N_STR_STARTS_WITH: u16 = NATIVE_BASE + 62;
pub const N_STR_ENDS_WITH: u16 = NATIVE_BASE + 63;
pub const N_STR_REPEAT: u16 = NATIVE_BASE + 64;
pub const N_STR_PAD_START: u16 = NATIVE_BASE + 65;
pub const N_STR_PAD_END: u16 = NATIVE_BASE + 66;
pub const N_STR_CONCAT: u16 = NATIVE_BASE + 67;
pub const N_STR_TOSTRING: u16 = NATIVE_BASE + 68; // String.prototype.toString/valueOf — validates `this` is a String
pub const N_STR_MATCH: u16 = NATIVE_BASE + 69;

// Array
pub const N_ARR_PUSH: u16 = NATIVE_BASE + 80;
pub const N_ARR_POP: u16 = NATIVE_BASE + 81;
pub const N_ARR_SHIFT: u16 = NATIVE_BASE + 82;
pub const N_ARR_UNSHIFT: u16 = NATIVE_BASE + 83;
pub const N_ARR_SPLICE: u16 = NATIVE_BASE + 84;
pub const N_ARR_SLICE: u16 = NATIVE_BASE + 85;
pub const N_ARR_INDEX_OF: u16 = NATIVE_BASE + 86;
pub const N_ARR_JOIN: u16 = NATIVE_BASE + 87;
pub const N_ARR_REVERSE: u16 = NATIVE_BASE + 88;
pub const N_ARR_SORT: u16 = NATIVE_BASE + 89;
pub const N_ARR_CONCAT: u16 = NATIVE_BASE + 90;
pub const N_ARR_INCLUDES: u16 = NATIVE_BASE + 91;
pub const N_ARR_FIND: u16 = NATIVE_BASE + 92;
pub const N_ARR_MAP: u16 = NATIVE_BASE + 93;
pub const N_ARR_FILTER: u16 = NATIVE_BASE + 94;
pub const N_ARR_REDUCE: u16 = NATIVE_BASE + 95;
pub const N_ARR_FOR_EACH: u16 = NATIVE_BASE + 96;
pub const N_ARR_FILL: u16 = NATIVE_BASE + 97;
pub const N_ARR_FLAT: u16 = NATIVE_BASE + 98;
pub const N_ARR_FROM: u16 = NATIVE_BASE + 99;
pub const N_ARR_IS_ARRAY: u16 = NATIVE_BASE + 100;
pub const N_ARR_SOME: u16 = NATIVE_BASE + 101;
pub const N_ARR_EVERY: u16 = NATIVE_BASE + 102;
pub const N_ARRAY_CTOR: u16 = NATIVE_BASE + 105; // Array(n) / Array(a,b,...)

// Object
pub const N_OBJ_KEYS: u16 = NATIVE_BASE + 110;
pub const N_OBJ_VALUES: u16 = NATIVE_BASE + 111;
pub const N_OBJ_ENTRIES: u16 = NATIVE_BASE + 112;
pub const N_OBJ_ASSIGN: u16 = NATIVE_BASE + 113;
pub const N_OBJ_CREATE: u16 = NATIVE_BASE + 114;
pub const N_OBJ_DEFINE_PROP: u16 = NATIVE_BASE + 115;
pub const N_OBJ_HAS_OWN: u16 = NATIVE_BASE + 116;
pub const N_OBJ_FREEZE: u16 = NATIVE_BASE + 117;
pub const N_OBJ_GET_PROTO: u16 = NATIVE_BASE + 118;
pub const N_OBJ_TOSTRING: u16 = NATIVE_BASE + 119; // Object.prototype.toString -> "[object Array]" etc.
pub const N_OBJ_IS_PROTO_OF: u16 = NATIVE_BASE + 120; // Object.prototype.isPrototypeOf
pub const N_OBJ_PROP_IS_ENUM: u16 = NATIVE_BASE + 121; // Object.prototype.propertyIsEnumerable
pub const N_OBJ_VALUE_OF: u16 = NATIVE_BASE + 122; // Object.prototype.valueOf -> this
pub const N_OBJ_GET_OWN_DESC: u16 = NATIVE_BASE + 123;

// Number / Date
pub const N_DATE_NOW: u16 = NATIVE_BASE + 130;
// performance.now(): a SMALL monotonic millisecond value (relative to page
// load), NOT the Date epoch. BotGuard's clock is `this.wM + performance.now()`;
// wiring performance.now to Date.now (a ~1.7e12 epoch) made the clock/timing
// budget (fi/Ci) astronomically large, so the timing-gate function (`pM`) took
// the wrong branch and mis-installed opcode handlers (live-challenge stage-9).
// Real browsers return small values here (ms since navigationStart).
pub const N_PERF_NOW: u16 = NATIVE_BASE + 240;
pub const N_STRING_CTOR: u16 = NATIVE_BASE + 241; // String(x) coercion (callable)
pub const N_OBJECT_CTOR: u16 = NATIVE_BASE + 242; // Object(x) (callable)
pub const N_NUMBER_IS_INTEGER: u16 = NATIVE_BASE + 131;
pub const N_NUMBER_IS_FINITE: u16 = NATIVE_BASE + 132;
pub const N_NUMBER_TO_STRING: u16 = NATIVE_BASE + 133;
pub const N_NUMBER_CTOR: u16 = NATIVE_BASE + 134; // Number(x) coercion (callable)
pub const N_DATE_CTOR: u16 = NATIVE_BASE + 135; // Date(...) / new Date() (callable)
pub const N_ERROR_CTOR: u16 = NATIVE_BASE + 136; // Error(msg) / ReferenceError / TypeError
pub const N_REFERROR_CTOR: u16 = NATIVE_BASE + 137;
pub const N_TYPEERROR_CTOR: u16 = NATIVE_BASE + 138;
pub const N_ERROR_TOSTRING: u16 = NATIVE_BASE + 139; // Error.prototype.toString -> "name: message"
pub const N_DOM_CREATE_ELEMENT: u16 = NATIVE_BASE + 142; // document.createElement -> element object
pub const N_DOM_NOOP: u16 = NATIVE_BASE + 143; // generic no-op element method (returns undefined)
pub const N_DOM_GET_CONTEXT: u16 = NATIVE_BASE + 144; // canvas getContext -> null
pub const N_DOM_EMPTY_ARRAY: u16 = NATIVE_BASE + 145; // getElementsByTagName/querySelectorAll -> []
pub const N_TT_CREATE_POLICY: u16 = NATIVE_BASE + 243; // trustedTypes.createPolicy -> passthrough policy
pub const N_TT_IDENTITY: u16 = NATIVE_BASE + 244; // policy.createScript/createHTML(s) -> s (passthrough)
pub const N_FN_TOSTRING: u16 = NATIVE_BASE + 245; // Function.prototype.toString -> source text
pub const N_REGEXP_CTOR: u16 = NATIVE_BASE + 246;
pub const N_REGEXP_EXEC: u16 = NATIVE_BASE + 247;
pub const N_REGEXP_TEST: u16 = NATIVE_BASE + 248;
pub const N_REGEXP_TOSTRING: u16 = NATIVE_BASE + 249;
var regexp_proto: u32 = objects.NULL_OBJ;

// TextEncoder/TextDecoder
pub const N_TEXT_ENCODE: u16 = NATIVE_BASE + 140;
pub const N_TEXT_DECODE: u16 = NATIVE_BASE + 141;

// Crypto
pub const N_CRYPTO_RANDOM: u16 = NATIVE_BASE + 150;

// Typed Arrays
pub const N_UINT8_ARRAY: u16 = NATIVE_BASE + 160;
pub const N_UINT16_ARRAY: u16 = NATIVE_BASE + 161;
pub const N_UINT32_ARRAY: u16 = NATIVE_BASE + 162;
pub const N_INT8_ARRAY: u16 = NATIVE_BASE + 163;
pub const N_ARRAY_BUFFER: u16 = NATIVE_BASE + 164;
pub const N_DATA_VIEW: u16 = NATIVE_BASE + 165;

// Promise (basic)
pub const N_PROMISE_RESOLVE: u16 = NATIVE_BASE + 170;
pub const N_PROMISE_REJECT: u16 = NATIVE_BASE + 171;

// Proxy
pub const N_PROXY_CONSTRUCTOR: u16 = NATIVE_BASE + 180;

// Symbol
pub const N_SYMBOL: u16 = NATIVE_BASE + 190;

// ── VM intrinsics (handled directly by the VM, NOT via callNative) ──
// These need compiler/VM re-entrancy (compile a string, run it in a frame),
// which callNative cannot express. The VM's callFunction special-cases them.
pub const N_EVAL: u16 = NATIVE_BASE + 200;
pub const N_FUNCTION: u16 = NATIVE_BASE + 201;

// Function.prototype.{call,apply,bind} bound-invokers. A bound invoker is a
// function object with one of these func_ids and a "__target__" property that
// stores the function it wraps. The VM handles them in callFunction.
pub const N_FN_CALL: u16 = NATIVE_BASE + 202;
pub const N_FN_APPLY: u16 = NATIVE_BASE + 203;
pub const N_FN_BIND: u16 = NATIVE_BASE + 204;
// A materialized bound function (result of `f.bind(thisArg, ...args)`): stores
// __target__, __boundThis__, __boundArgs__ (array). Invoking it calls target
// with this=__boundThis__ and boundArgs prepended to the call args.
pub const N_FN_BOUND: u16 = NATIVE_BASE + 205;

// BotGuard host callbacks. These are native function values passed INTO the
// BotGuard VM (via trayride.a(...)). When the VM invokes them, we capture the
// arguments it hands back (the VM functions, and the final snapshot response).
pub const N_BG_VM_SETUP: u16 = NATIVE_BASE + 220; // (asyncSnapshot, shutdown, passEvent, checkCamera)
pub const N_BG_SNAPSHOT_RESULT: u16 = NATIVE_BASE + 221; // (responseString)
pub const N_BG_TELEMETRY: u16 = NATIVE_BASE + 222; // (latency, flag1, flag2) -> ignored
pub const N_BG_LOGGER: u16 = NATIVE_BASE + 223; // various logger fns -> ignored

// Captured BotGuard VM state, populated when the VM invokes the host callbacks.
pub var bg_async_snapshot_fn: Value = Value.UNDEFINED; // VM's asyncSnapshotFunction
pub var bg_shutdown_fn: Value = Value.UNDEFINED;
pub var bg_pass_event_fn: Value = Value.UNDEFINED;
pub var bg_check_camera_fn: Value = Value.UNDEFINED;
pub var bg_vm_setup_called: bool = false;
/// The global object index (set by env.installEnvironment). Used so a created
/// DOM element's `contentWindow`/`contentDocument` resolve to a real window-like
/// realm (BotGuard reads `iframe.contentWindow` to obtain a pristine `String`/
/// `eval` from a fresh realm — returning undefined breaks its register machine).
pub var g_global_obj: u32 = 0;
pub var dbg_bg_telemetry_calls: u32 = 0;
pub var dbg_bg_logger_calls: u32 = 0;
pub var bg_snapshot_response: Value = Value.UNDEFINED; // captured botguardResponse string
pub var bg_snapshot_result_called: bool = false;

// Deferred task queue for setTimeout/setInterval. BotGuard schedules its VM
// setup (and other work) via setTimeout(fn, 0); the host VM must drain these
// after the synchronous call returns. Callbacks are enqueued here (with up to
// two bound args) and executed by vm.drainTasks().
const MAX_TASKS: usize = 256;
pub var task_fns: [MAX_TASKS]Value = undefined;
pub var task_arg0: [MAX_TASKS]Value = undefined;
pub var task_arg1: [MAX_TASKS]Value = undefined;
pub var task_argc: [MAX_TASKS]u8 = undefined;
pub var task_head: usize = 0; // next task to run
pub var task_tail: usize = 0; // next free slot
pub fn taskQueueReset() void { task_head = 0; task_tail = 0; }
fn enqueueTask(args: []const Value) void {
    // args[0] = callback fn, args[1] = delay (ignored), args[2..] = fn args.
    if (args.len == 0 or args[0].tag != .function) return;
    if (task_tail >= MAX_TASKS) return;
    task_fns[task_tail] = args[0];
    task_arg0[task_tail] = if (args.len > 2) args[2] else Value.UNDEFINED;
    task_arg1[task_tail] = if (args.len > 3) args[3] else Value.UNDEFINED;
    var extra: u8 = 0;
    if (args.len > 2) extra += 1;
    if (args.len > 3) extra += 1;
    task_argc[task_tail] = extra;
    task_tail += 1;
}

/// Reset captured BotGuard callback state before an invocation.
pub fn bgResetCallbackState() void {
    bg_async_snapshot_fn = Value.UNDEFINED;
    bg_shutdown_fn = Value.UNDEFINED;
    bg_pass_event_fn = Value.UNDEFINED;
    bg_check_camera_fn = Value.UNDEFINED;
    bg_vm_setup_called = false;
    bg_snapshot_response = Value.UNDEFINED;
    bg_snapshot_result_called = false;
}

/// True if a func_id is a VM intrinsic that must be handled by the VM itself.
pub fn isVmIntrinsic(func_id: u16) bool {
    return func_id == N_EVAL or func_id == N_FUNCTION;
}

/// True for global coercion/utility natives whose result does NOT depend on the
/// `this` receiver (JS: `x.String(v)` === `String(v)`). When such a native is
/// invoked as a method, the VM must NOT prepend the receiver as args[0] — the
/// first real argument is the operand. (String/Number/Object/Boolean coercion,
/// parseInt/parseFloat, isNaN/isFinite, encode/decodeURIComponent, atob/btoa.)
pub fn nativeIgnoresReceiver(func_id: u16) bool {
    if (func_id >= N_MATH_FLOOR and func_id <= N_MATH_FROUND) return true;
    if (func_id == N_JSON_PARSE or func_id == N_JSON_STRINGIFY or
        func_id == N_STR_FROM_CHARCODE or func_id == N_ARR_IS_ARRAY or
        func_id == N_ARR_FROM or func_id == N_ARRAY_CTOR or
        func_id == N_NUMBER_IS_INTEGER or func_id == N_NUMBER_IS_FINITE or
        func_id == N_DATE_NOW or func_id == N_PERF_NOW or
        func_id == N_DATE_CTOR or func_id == N_ERROR_CTOR or
        func_id == N_REFERROR_CTOR or func_id == N_TYPEERROR_CTOR or
        func_id == N_UINT8_ARRAY or func_id == N_UINT16_ARRAY or
        func_id == N_UINT32_ARRAY or func_id == N_INT8_ARRAY or
        func_id == N_ARRAY_BUFFER or func_id == N_DATA_VIEW or
        func_id == N_SYMBOL or func_id == N_PROXY_CONSTRUCTOR or
        func_id == N_SET_TIMEOUT or func_id == N_SET_INTERVAL or
        func_id == N_CLEAR_TIMEOUT or func_id == N_CONSOLE_LOG or
        func_id == N_BG_VM_SETUP or func_id == N_BG_SNAPSHOT_RESULT or
        func_id == N_BG_TELEMETRY or func_id == N_BG_LOGGER) return true;
    return func_id == N_STRING_CTOR or func_id == N_NUMBER_CTOR or func_id == N_REGEXP_CTOR or
        func_id == N_OBJECT_CTOR or func_id == N_PARSE_INT or func_id == N_PARSE_FLOAT or
        func_id == N_IS_NAN or func_id == N_IS_FINITE or
        func_id == N_ENCODE_URI or func_id == N_DECODE_URI or
        func_id == N_ATOB or func_id == N_BTOA;
}

/// True if a func_id is a Function.prototype method bound-invoker.
pub fn isFnMethod(func_id: u16) bool {
    // NOTE: N_FN_TOSTRING is NOT an fn-method here — it dispatches as a normal
    // native method (callNative, receiver=args[0]) so it gets the function receiver.
    return func_id == N_FN_CALL or func_id == N_FN_APPLY or func_id == N_FN_BIND or func_id == N_FN_BOUND;
}

// ── Random state (xorshift64) ──

var rng_state: u64 = 0x1234567890ABCDEF;

// ── Install Globals ──

/// Install all built-in functions and objects on the global object.
pub var dbg_disable_proto_wire: bool = false;
pub fn installGlobals(global: u32) void {
    // Math object
    const math_obj = objects.createObject();
    installNativeMethod(math_obj, "floor", N_MATH_FLOOR);
    installNativeMethod(math_obj, "ceil", N_MATH_CEIL);
    installNativeMethod(math_obj, "round", N_MATH_ROUND);
    installNativeMethod(math_obj, "abs", N_MATH_ABS);
    installNativeMethod(math_obj, "min", N_MATH_MIN);
    installNativeMethod(math_obj, "max", N_MATH_MAX);
    installNativeMethod(math_obj, "random", N_MATH_RANDOM);
    installNativeMethod(math_obj, "pow", N_MATH_POW);
    installNativeMethod(math_obj, "log", N_MATH_LOG);
    installNativeMethod(math_obj, "sqrt", N_MATH_SQRT);
    installNativeMethod(math_obj, "sign", N_MATH_SIGN);
    installNativeMethod(math_obj, "trunc", N_MATH_TRUNC);
    installNativeMethod(math_obj, "clz32", N_MATH_CLZ32);
    installNativeMethod(math_obj, "imul", N_MATH_IMUL);
    installNativeMethod(math_obj, "fround", N_MATH_FROUND);
    // Math constants
    objects.setProperty(math_obj, values.internString("PI"), Value.number(3.141592653589793));
    objects.setProperty(math_obj, values.internString("E"), Value.number(2.718281828459045));
    objects.setProperty(math_obj, values.internString("LN2"), Value.number(0.6931471805599453));
    objects.setProperty(math_obj, values.internString("LN10"), Value.number(2.302585092994046));
    objects.setProperty(global, values.internString("Math"), Value.object(math_obj));

    // JSON object
    const json_obj = objects.createObject();
    installNativeMethod(json_obj, "parse", N_JSON_PARSE);
    installNativeMethod(json_obj, "stringify", N_JSON_STRINGIFY);
    objects.setProperty(global, values.internString("JSON"), Value.object(json_obj));

    // console object
    const console_obj = objects.createObject();
    installNativeMethod(console_obj, "log", N_CONSOLE_LOG);
    installNativeMethod(console_obj, "warn", N_CONSOLE_LOG);
    installNativeMethod(console_obj, "error", N_CONSOLE_LOG);
    objects.setProperty(global, values.internString("console"), Value.object(console_obj));

    // Global functions
    installNativeGlobal(global, "parseInt", N_PARSE_INT);
    installNativeGlobal(global, "parseFloat", N_PARSE_FLOAT);
    installNativeGlobal(global, "isNaN", N_IS_NAN);
    installNativeGlobal(global, "isFinite", N_IS_FINITE);
    installNativeGlobal(global, "encodeURIComponent", N_ENCODE_URI);
    installNativeGlobal(global, "decodeURIComponent", N_DECODE_URI);
    installNativeGlobal(global, "atob", N_ATOB);
    installNativeGlobal(global, "btoa", N_BTOA);
    installNativeGlobal(global, "setTimeout", N_SET_TIMEOUT);
    installNativeGlobal(global, "setInterval", N_SET_INTERVAL);
    installNativeGlobal(global, "clearTimeout", N_CLEAR_TIMEOUT);
    installNativeGlobal(global, "clearInterval", N_CLEAR_TIMEOUT);

    // String — a CALLABLE coercion function (String(x) -> "x") carrying static
    // methods (fromCharCode). BotGuard calls `String(x)` and reads `L.String`
    // expecting a function; a plain object broke `typeof String==='function'`,
    // `String(x)` calls, and `L.String.<...>` accesses (→ payload-inflating throws).
    const string_obj = objects.createFunction(N_STRING_CTOR);
    installNativeMethod(string_obj, "fromCharCode", N_STR_FROM_CHARCODE);
    if (!dbg_disable_proto_wire) {
        objects.setProperty(string_obj, values.internString("prototype"), Value.object(objects.getStringProto()));
        objects.setProperty(objects.getStringProto(), values.internString("constructor"), Value.function(string_obj));
        objects.setEnumerable(objects.getStringProto(), values.internString("constructor"), false);
    }
    objects.setProperty(global, values.internString("String"), Value.function(string_obj));

    regexp_proto = objects.createObject();
    installNativeMethod(regexp_proto, "exec", N_REGEXP_EXEC);
    installNativeMethod(regexp_proto, "test", N_REGEXP_TEST);
    installNativeMethod(regexp_proto, "toString", N_REGEXP_TOSTRING);
    const regexp_ctor = objects.createFunction(N_REGEXP_CTOR);
    objects.setProperty(regexp_ctor, values.internString("prototype"), Value.object(regexp_proto));
    objects.setProperty(regexp_proto, values.internString("constructor"), Value.function(regexp_ctor));
    objects.setEnumerable(regexp_proto, values.internString("constructor"), false);
    objects.setProperty(global, values.internString("RegExp"), Value.function(regexp_ctor));

    // Object — a CALLABLE constructor function carrying the static methods.
    const obj_constructor = objects.createFunction(N_OBJECT_CTOR);
    installNativeMethod(obj_constructor, "keys", N_OBJ_KEYS);
    installNativeMethod(obj_constructor, "values", N_OBJ_VALUES);
    installNativeMethod(obj_constructor, "entries", N_OBJ_ENTRIES);
    installNativeMethod(obj_constructor, "assign", N_OBJ_ASSIGN);
    installNativeMethod(obj_constructor, "create", N_OBJ_CREATE);
    installNativeMethod(obj_constructor, "defineProperty", N_OBJ_DEFINE_PROP);
    installNativeMethod(obj_constructor, "getOwnPropertyDescriptor", N_OBJ_GET_OWN_DESC);
    installNativeMethod(obj_constructor, "freeze", N_OBJ_FREEZE);
    installNativeMethod(obj_constructor, "getPrototypeOf", N_OBJ_GET_PROTO);
    // Object.prototype must be the shared object_proto so that
    // `Object.prototype.toString.call(x)` resolves the real toString and
    // `x instanceof Object` walks the correct proto.
    if (!dbg_disable_proto_wire) {
        objects.setProperty(obj_constructor, values.internString("prototype"), Value.object(objects.getObjectProto()));
        // Object.prototype.constructor === Object. BotGuard uses `x.constructor`
        // extensively for type detection; without this every `.constructor`
        // returns undefined and downstream `.prototype` accesses throw.
        objects.setProperty(objects.getObjectProto(), values.internString("constructor"), Value.function(obj_constructor));
        objects.setEnumerable(objects.getObjectProto(), values.internString("constructor"), false);
    }
    objects.setProperty(global, values.internString("Object"), Value.function(obj_constructor));

    // Array — a callable constructor function with static methods attached.
    const arr_ctor = objects.createFunction(N_ARRAY_CTOR);
    installNativeMethod(arr_ctor, "isArray", N_ARR_IS_ARRAY);
    installNativeMethod(arr_ctor, "from", N_ARR_FROM);
    // Array.prototype must be the shared array_proto so `x instanceof Array`
    // and `Array.prototype`-based checks work.
    if (!dbg_disable_proto_wire) {
        objects.setProperty(arr_ctor, values.internString("prototype"), Value.object(objects.getArrayProto()));
        objects.setProperty(objects.getArrayProto(), values.internString("constructor"), Value.function(arr_ctor));
        objects.setEnumerable(objects.getArrayProto(), values.internString("constructor"), false);
    }
    objects.setProperty(global, values.internString("Array"), Value.function(arr_ctor));

    // Number — a callable coercion function (Number("5") -> 5) that also carries
    // static methods (Number.isInteger, ...). BotGuard calls Number(x) directly,
    // so it must be a function value, not a plain object.
    const num_ctor = objects.createFunction(N_NUMBER_CTOR);
    installNativeMethod(num_ctor, "isInteger", N_NUMBER_IS_INTEGER);
    installNativeMethod(num_ctor, "isFinite", N_NUMBER_IS_FINITE);
    objects.setProperty(num_ctor, values.internString("MAX_SAFE_INTEGER"), Value.number(9007199254740991));
    if (!dbg_disable_proto_wire and objects.getNumberProto() != objects.NULL_OBJ) {
        objects.setProperty(num_ctor, values.internString("prototype"), Value.object(objects.getNumberProto()));
        objects.setProperty(objects.getNumberProto(), values.internString("constructor"), Value.function(num_ctor));
        objects.setEnumerable(objects.getNumberProto(), values.internString("constructor"), false);
    }
    objects.setProperty(global, values.internString("Number"), Value.function(num_ctor));

    // Date — callable (Date() / new Date()) with static Date.now().
    const date_ctor = objects.createFunction(N_DATE_CTOR);
    installNativeMethod(date_ctor, "now", N_DATE_NOW);
    objects.setProperty(global, values.internString("Date"), Value.function(date_ctor));

    // Error / ReferenceError / TypeError — callable constructors. BotGuard does
    // `throw Error(...)` and inspects e.message / String(e). Each builds an
    // object with { name, message } and the shared error prototype (toString).
    const err_ctor = objects.createFunction(N_ERROR_CTOR);
    objects.setProperty(err_ctor, values.internString("prototype"), Value.object(objects.getErrorProto()));
    objects.setProperty(global, values.internString("Error"), Value.function(err_ctor));
    const referr_ctor = objects.createFunction(N_REFERROR_CTOR);
    objects.setProperty(global, values.internString("ReferenceError"), Value.function(referr_ctor));
    const typeerr_ctor = objects.createFunction(N_TYPEERROR_CTOR);
    objects.setProperty(global, values.internString("TypeError"), Value.function(typeerr_ctor));
    // Error.prototype.toString -> "name: message"
    installNativeMethod(objects.getErrorProto(), "toString", N_ERROR_TOSTRING);

    // Typed array constructors
    installNativeGlobal(global, "Uint8Array", N_UINT8_ARRAY);
    installNativeGlobal(global, "Uint16Array", N_UINT16_ARRAY);
    installNativeGlobal(global, "Uint32Array", N_UINT32_ARRAY);
    installNativeGlobal(global, "Int8Array", N_INT8_ARRAY);
    installNativeGlobal(global, "ArrayBuffer", N_ARRAY_BUFFER);
    installNativeGlobal(global, "DataView", N_DATA_VIEW);

    // TextEncoder / TextDecoder
    installNativeGlobal(global, "TextEncoder", N_TEXT_ENCODE);
    installNativeGlobal(global, "TextDecoder", N_TEXT_DECODE);

    // Proxy
    installNativeGlobal(global, "Proxy", N_PROXY_CONSTRUCTOR);

    // Promise
    const promise_obj = objects.createObject();
    installNativeMethod(promise_obj, "resolve", N_PROMISE_RESOLVE);
    installNativeMethod(promise_obj, "reject", N_PROMISE_REJECT);
    objects.setProperty(global, values.internString("Promise"), Value.object(promise_obj));

    // Symbol
    installNativeGlobal(global, "Symbol", N_SYMBOL);

    // VM intrinsics: eval + Function (BotGuard self-unpacks via indirect eval).
    installNativeGlobal(global, "eval", N_EVAL);
    installNativeGlobal(global, "Function", N_FUNCTION);

    // Prototype methods so obj.method(...) resolves via the prototype chain.
    installPrototypes();

    // Function.prototype.constructor === Function (`(fn).constructor` is used by
    // BotGuard type detection). Function global was installed just above.
    if (!dbg_disable_proto_wire) {
        const func_ctor = objects.getProperty(global, values.internString("Function"));
        if (func_ctor.tag == .function) {
            objects.setProperty(objects.getFunctionProto(), values.internString("constructor"), func_ctor);
            objects.setEnumerable(objects.getFunctionProto(), values.internString("constructor"), false);
        }
    }

    // Function.prototype.toString -> source text. BotGuard self-rehydrates its
    // decoder functions via `eval("NAME="+fn.toString())`, so this MUST return the
    // real source (user funcs) / "[native code]" (natives). Dispatched as a native
    // method (receiver=args[0]) handled by callNative -> fnToStringNative. Object.
    // prototype.toString still returns "[object Function]" (type-detection intact).
    installNativeMethod(objects.getFunctionProto(), "toString", N_FN_TOSTRING);





    // Constants
    objects.setProperty(global, values.internString("undefined"), Value.UNDEFINED);
    objects.setProperty(global, values.internString("NaN"), Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000)))));
    objects.setProperty(global, values.internString("Infinity"), Value.number(@as(f64, @bitCast(@as(u64, 0x7FF0000000000000)))));
}

/// Install Array.prototype / String.prototype methods on the shared prototype
/// objects. Method calls (obj.m(...)) resolve here via the prototype chain and
/// pass the receiver as args[0] to the native (see VM callMethod).
fn installPrototypes() void {
    const ap = objects.getArrayProto();
    installNativeMethod(ap, "push", N_ARR_PUSH);
    installNativeMethod(ap, "pop", N_ARR_POP);
    installNativeMethod(ap, "shift", N_ARR_SHIFT);
    installNativeMethod(ap, "unshift", N_ARR_UNSHIFT);
    installNativeMethod(ap, "splice", N_ARR_SPLICE);
    installNativeMethod(ap, "slice", N_ARR_SLICE);
    installNativeMethod(ap, "indexOf", N_ARR_INDEX_OF);
    installNativeMethod(ap, "join", N_ARR_JOIN);
    // Array.prototype.toString === join with default "," separator (JS spec).
    // Without this, `arr.toString()` fell through to Object.prototype.toString
    // ("[object Array]") instead of "1,2,3" — BotGuard stringifies arrays.
    installNativeMethod(ap, "toString", N_ARR_JOIN);
    installNativeMethod(ap, "reverse", N_ARR_REVERSE);
    installNativeMethod(ap, "sort", N_ARR_SORT);
    installNativeMethod(ap, "concat", N_ARR_CONCAT);
    installNativeMethod(ap, "includes", N_ARR_INCLUDES);
    installNativeMethod(ap, "find", N_ARR_FIND);
    installNativeMethod(ap, "map", N_ARR_MAP);
    installNativeMethod(ap, "filter", N_ARR_FILTER);
    installNativeMethod(ap, "reduce", N_ARR_REDUCE);
    installNativeMethod(ap, "forEach", N_ARR_FOR_EACH);
    installNativeMethod(ap, "some", N_ARR_SOME);
    installNativeMethod(ap, "every", N_ARR_EVERY);
    installNativeMethod(ap, "fill", N_ARR_FILL);

    const sp2 = objects.getStringProto();
    installNativeMethod(sp2, "charAt", N_STR_CHAR_AT);
    installNativeMethod(sp2, "charCodeAt", N_STR_CHAR_CODE_AT);
    installNativeMethod(sp2, "indexOf", N_STR_INDEX_OF);
    installNativeMethod(sp2, "slice", N_STR_SLICE);
    installNativeMethod(sp2, "substring", N_STR_SUBSTRING);
    installNativeMethod(sp2, "substr", N_STR_SLICE);
    installNativeMethod(sp2, "split", N_STR_SPLIT);
    installNativeMethod(sp2, "replace", N_STR_REPLACE);
    installNativeMethod(sp2, "match", N_STR_MATCH);
    installNativeMethod(sp2, "trim", N_STR_TRIM);
    installNativeMethod(sp2, "toLowerCase", N_STR_TO_LOWER);
    installNativeMethod(sp2, "toUpperCase", N_STR_TO_UPPER);
    installNativeMethod(sp2, "includes", N_STR_INCLUDES);
    installNativeMethod(sp2, "startsWith", N_STR_STARTS_WITH);
    installNativeMethod(sp2, "endsWith", N_STR_ENDS_WITH);
    installNativeMethod(sp2, "repeat", N_STR_REPEAT);
    installNativeMethod(sp2, "padStart", N_STR_PAD_START);
    installNativeMethod(sp2, "padEnd", N_STR_PAD_END);
    installNativeMethod(sp2, "concat", N_STR_CONCAT);
    // String.prototype.toString / valueOf: JS-correct implementations that
    // THROW a TypeError when `this` is not a String (or String wrapper). Without
    // these, the lookup falls through to Object.prototype.toString, which does
    // NOT validate `this` — so `String.prototype.toString.apply(nonString)`
    // wrongly succeeds. BotGuard relies on this throw (it reads a string's
    // `.toString` then applies it to a non-string receiver expecting the throw;
    // succeeding instead populates a register that must stay empty, desyncing
    // the whole opcode dispatch).
    installNativeMethod(sp2, "toString", N_STR_TOSTRING);
    installNativeMethod(sp2, "valueOf", N_STR_TOSTRING);

    // Object.prototype.toString -> "[object <Kind>]" (used by type detection,
    // e.g. Object.prototype.toString.call(x) === "[object Array]"). Install on
    // the object/array/function prototypes so it's found via the chain.
    if (!dbg_disable_proto_wire) {
        const op = objects.getObjectProto();
        installNativeMethod(op, "toString", N_OBJ_TOSTRING);
        // Object.prototype.hasOwnProperty — BotGuard uses the canonical
        // `Object.prototype.hasOwnProperty.call(obj, key)` idiom throughout, so
        // this MUST be a real callable resolvable via the prototype chain (not
        // just an inline method) or `.call` on it yields undefined.
        installNativeMethod(op, "hasOwnProperty", N_OBJ_HAS_OWN);
        installNativeMethod(op, "isPrototypeOf", N_OBJ_IS_PROTO_OF);
        installNativeMethod(op, "propertyIsEnumerable", N_OBJ_PROP_IS_ENUM);
        installNativeMethod(op, "valueOf", N_OBJ_VALUE_OF);
        // Number.prototype.toString / valueOf — `(n).toString(radix)` must format
        // the number, NOT fall through to Object.prototype.toString ("[object
        // Number]"). Install on number_proto (and its toString beats the inherited
        // Object one via the prototype chain).
        const np = objects.getNumberProto();
        if (np != objects.NULL_OBJ) {
            installNativeMethod(np, "toString", N_NUMBER_TO_STRING);
            installNativeMethod(np, "valueOf", N_OBJ_VALUE_OF);
        }
        // String.prototype.toString/valueOf return the string itself.
        const sp2b = objects.getStringProto();
        if (sp2b != objects.NULL_OBJ) {
            installNativeMethod(sp2b, "valueOf", N_OBJ_VALUE_OF);
        }
    }
}

// ── Call Native ──

/// Dispatch a native function call.
/// A native builtin can request the VM raise a TypeError by setting this flag +
/// message; the VM checks it after callNative and throws (JS-correct). Used by
/// String.prototype.toString/valueOf when `this` is not a String.
pub var native_throw: bool = false;
pub var native_throw_msg_buf: [160]u8 = undefined;
pub var native_throw_msg_len: usize = 0;
pub fn nativeThrowMsg() []const u8 { return native_throw_msg_buf[0..native_throw_msg_len]; }
fn requestNativeThrow(msg: []const u8) void {
    native_throw = true;
    const n = @min(msg.len, native_throw_msg_buf.len);
    @memcpy(native_throw_msg_buf[0..n], msg[0..n]);
    native_throw_msg_len = n;
}

/// String.prototype.toString / valueOf. `this` (args[0]) must be a primitive
/// string (or a String wrapper). Otherwise JS throws a TypeError.
fn strToStringMethod(args: []const Value) Value {
    if (args.len > 0 and args[0].tag == .string) return args[0];
    // (We don't model boxed String objects; a real string primitive is the
    // only valid `this` here.) Anything else -> TypeError, matching V8.
    requestNativeThrow("String.prototype.toString requires that 'this' be a String");
    return Value.UNDEFINED;
}

pub fn callNative(func_id: u16, args: []const Value, argc: u8) Value {
    _ = argc;
    return switch (func_id) {
        N_MATH_FLOOR => mathFloor(args),
        N_MATH_CEIL => mathCeil(args),
        N_MATH_ROUND => mathRound(args),
        N_MATH_ABS => mathAbs(args),
        N_MATH_MIN => mathMin(args),
        N_MATH_MAX => mathMax(args),
        N_MATH_RANDOM => mathRandom(),
        N_MATH_POW => mathPowN(args),
        N_MATH_LOG => mathLog(args),
        N_MATH_SQRT => mathSqrt(args),
        N_MATH_SIGN => mathSign(args),
        N_MATH_TRUNC => mathTrunc(args),
        N_MATH_CLZ32 => mathClz32(args),
        N_MATH_IMUL => mathImul(args),
        N_MATH_FROUND => if (args.len > 0) Value.number(@as(f64, @as(f32, @floatCast(args[0].toNumber())))) else Value.number(0),
        N_PARSE_INT => nParseInt(args),
        N_PARSE_FLOAT => nParseFloat(args),
        N_IS_NAN => if (args.len > 0) boolVal(args[0].toNumber() != args[0].toNumber()) else Value.TRUE,
        N_IS_FINITE => nIsFinite(args),
        N_ATOB => nAtob(args),
        N_BTOA => nBtoa(args),
        N_SET_TIMEOUT => blk: { enqueueTask(args); break :blk Value.number(0); },
        N_SET_INTERVAL => Value.number(0), // intervals not run (would loop forever)
        N_CLEAR_TIMEOUT => Value.UNDEFINED,
        N_CONSOLE_LOG => nConsoleLog(args),
        N_STR_FROM_CHARCODE => strFromCharCode(args),
        N_STR_CHAR_AT => strCharAt(args),
        N_STR_CHAR_CODE_AT => strCharCodeAt(args),
        N_STR_INDEX_OF => strIndexOf(args),
        N_STR_SLICE => strSlice(args),
        N_STR_SUBSTRING => strSlice(args), // similar semantics
        N_STR_SPLIT => strSplit(args),
        N_STR_REPLACE => strReplace(args),
        N_STR_MATCH => strMatch(args),
        N_STR_TRIM => strTrim(args),
        N_STR_TO_LOWER => strToLower(args),
        N_STR_TO_UPPER => strToUpper(args),
        N_STR_INCLUDES => strIncludes(args),
        N_STR_STARTS_WITH => strStartsWith(args),
        N_STR_ENDS_WITH => strEndsWith(args),
        N_STR_REPEAT => strRepeat(args),
        N_STR_PAD_START => strPadStart(args),
        N_STR_PAD_END => strPadEnd(args),
        N_STR_CONCAT => strConcat(args),
        N_STR_TOSTRING => strToStringMethod(args),
        N_ARR_PUSH => arrPush(args),
        N_ARR_POP => arrPop(args),
        N_ARR_JOIN => arrJoin(args),
        N_ARR_INCLUDES => arrIncludes(args),
        N_ARR_INDEX_OF => arrIndexOf(args),
        N_ARR_IS_ARRAY => if (args.len > 0 and isArrayVal(args[0])) Value.TRUE else Value.FALSE,
        N_ARR_SLICE => arrSlice(args),
        N_ARR_FROM => arrFrom(args),
        N_ARRAY_CTOR => arrayCtor(args),
        N_ARR_FILL => arrFill(args),
        N_ARR_FLAT => arrFlat(args),
        N_ARR_SORT => arrSort(args),
        N_ARR_REVERSE => arrReverse(args),
        // map/filter/reduce/forEach/find/some/every need callback execution and
        // are handled with VM re-entrancy in vm.sig (isArrayIterMethod). Reaching
        // them here means they were grabbed via .call/.apply without a callback
        // path; return a benign value rather than corrupting state.
        N_ARR_MAP, N_ARR_FILTER, N_ARR_REDUCE, N_ARR_FOR_EACH, N_ARR_FIND, N_ARR_SOME, N_ARR_EVERY => Value.UNDEFINED,
        N_ARR_SHIFT => arrShift(args),
        N_ARR_UNSHIFT => arrUnshift(args),
        N_ARR_SPLICE => arrSplice(args),
        N_ARR_CONCAT => arrConcat(args),
        N_OBJ_KEYS => objKeys(args),
        N_OBJ_ASSIGN => objAssign(args),
        N_OBJ_CREATE => objCreate(args),
        N_OBJ_FREEZE => if (args.len > 0) args[0] else Value.UNDEFINED,
        N_OBJ_GET_PROTO => objGetProto(args),
        N_OBJ_DEFINE_PROP => objDefineProperty(args),
        N_OBJ_GET_OWN_DESC => objGetOwnDescriptor(args),
        N_OBJ_HAS_OWN => objHasOwn(args),
        N_OBJ_IS_PROTO_OF => objIsPrototypeOf(args),
        N_OBJ_PROP_IS_ENUM => objPropertyIsEnumerable(args),
        N_OBJ_VALUE_OF => if (args.len > 0) args[0] else Value.UNDEFINED,
        N_OBJ_VALUES => objValues(args),
        N_OBJ_ENTRIES => objEntries(args),
        N_DATE_NOW => dateNow(),
        N_PERF_NOW => perfNow(),
        N_NUMBER_CTOR => if (args.len > 0) Value.number(args[0].toNumber()) else Value.number(0),
        N_STRING_CTOR => stringCtor(args),
        N_OBJECT_CTOR => objectCtor(args),
        N_DATE_CTOR => dateNow(), // Date()/new Date() -> current epoch ms (numeric)
        N_ERROR_CTOR => makeErrorVal("Error", args),
        N_REFERROR_CTOR => makeErrorVal("ReferenceError", args),
        N_TYPEERROR_CTOR => makeErrorVal("TypeError", args),
        N_ERROR_TOSTRING => errorToString(args),
        N_DOM_CREATE_ELEMENT => makeDomElement(),
        N_DOM_NOOP => Value.UNDEFINED,
        N_DOM_GET_CONTEXT => Value.NULL,
        N_DOM_EMPTY_ARRAY => Value.object(objects.createArray(0)),
        N_TT_CREATE_POLICY => makeTrustedTypesPolicy(),
        N_TT_IDENTITY => ttIdentity(args),
        N_FN_TOSTRING => fnToStringNative(args),
        N_REGEXP_CTOR => regexpCtor(args),
        N_REGEXP_EXEC => regexpExec(args, false),
        N_REGEXP_TEST => regexpExec(args, true),
        N_REGEXP_TOSTRING => regexpToString(args),
        N_NUMBER_IS_INTEGER => if (args.len > 0) boolVal(isInteger(args[0])) else Value.FALSE,
        N_NUMBER_IS_FINITE => nIsFinite(args),
        N_NUMBER_TO_STRING => numberToString(args),
        N_TEXT_ENCODE => textEncode(args),
        N_TEXT_DECODE => textDecode(args),
        N_CRYPTO_RANDOM => cryptoRandom(args),
        N_UINT8_ARRAY => createTypedArrayN(args, 1),
        N_UINT16_ARRAY => createTypedArrayN(args, 2),
        N_UINT32_ARRAY => createTypedArrayN(args, 4),
        N_INT8_ARRAY => createTypedArrayN(args, 1),
        N_ARRAY_BUFFER => createArrayBufferN(args),
        N_DATA_VIEW => createDataViewN(args),
        N_PROMISE_RESOLVE => if (args.len > 0) args[0] else Value.UNDEFINED,
        N_PROMISE_REJECT => Value.UNDEFINED,
        N_PROXY_CONSTRUCTOR => if (args.len > 0) args[0] else Value.object(objects.createObject()),
        N_SYMBOL => Value.UNDEFINED,
        N_JSON_PARSE => jsonParse(args),
        N_JSON_STRINGIFY => jsonStringify(args),
        N_ENCODE_URI, N_DECODE_URI => if (args.len > 0) args[0] else Value.UNDEFINED,
        N_OBJ_TOSTRING => objProtoToString(args),
        N_BG_VM_SETUP => bgVmSetup(args),
        N_BG_SNAPSHOT_RESULT => bgSnapshotResult(args),
        N_BG_TELEMETRY => blk: { dbg_bg_telemetry_calls += 1; break :blk Value.UNDEFINED; },
        N_BG_LOGGER => blk: { dbg_bg_logger_calls += 1; break :blk Value.UNDEFINED; },
        else => Value.UNDEFINED,
    };
}

/// Object.prototype.toString: returns "[object <Kind>]" for the receiver
/// (args[0] under the method-call convention). Distinguishes Array vs Object
/// via the object's obj_type — critical for BotGuard's array type detection.
fn objProtoToString(args: []const Value) Value {
    const recv = if (args.len > 0) args[0] else Value.UNDEFINED;
    const tag: []const u8 = switch (recv.tag) {
        .undefined => "[object Undefined]",
        .null_val => "[object Null]",
        .boolean => "[object Boolean]",
        .number => "[object Number]",
        .string => "[object String]",
        .function => "[object Function]",
        .array => "[object Array]",
        .object => blk: {
            const ot = objects.getObject(recv.data.obj_idx).obj_type;
            break :blk if (objects.isArguments(recv.data.obj_idx)) "[object Arguments]" else if (ot == .array) "[object Array]" else if (ot == .function) "[object Function]" else if (ot == .regexp) "[object RegExp]" else "[object Object]";
        },
        else => "[object Object]",
    };
    return Value.string(values.internString(tag));
}

/// Convert a property-key Value to a string-pool name index (for property
/// lookups). String keys use their pooled index directly; numbers are
/// formatted as decimal; booleans/undefined/null use their literal spelling.
/// String(x) — coerce the first arg to a string (JS ToString). Callable global
/// constructor form (BotGuard uses `String(x)` and `L.String`). For objects we
/// return "[object Object]" here; the VM's own value→string coercion handles the
/// richer cases (arrays join, Error toString) when used via `""+x`.
fn stringCtor(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const v = args[0];
    return switch (v.tag) {
        .string => v,
        .number => blk: {
            var buf: [40]u8 = undefined;
            const n = numberToDecimal(v.data.number, &buf);
            break :blk Value.string(values.internString(buf[0..n]));
        },
        .boolean => Value.string(values.internString(if (v.data.boolean != 0) "true" else "false")),
        .null_val => Value.string(values.internString("null")),
        .undefined => Value.string(values.internString("undefined")),
        // For objects/arrays/functions, defer to the object's toString via the
        // VM; a plain fallback keeps String() total. The VM routes most of these
        // through valueToStringIdx already; here return a safe default.
        else => Value.string(values.internString("[object Object]")),
    };
}

/// Object(x) — JS: returns x if it's already an object; wraps primitives (we
/// return a fresh empty object for primitives, sufficient for BotGuard which
/// uses Object(x) mainly to ensure an object and to reach Object.* statics).
fn objectCtor(args: []const Value) Value {
    if (args.len > 0 and (args[0].tag == .object or args[0].tag == .array or args[0].tag == .function)) return args[0];
    return Value.object(objects.createObject());
}

/// Minimal number→decimal string (integers exact; fractional best-effort) for
/// String(number). Returns bytes written.
fn numberToDecimal(n: f64, buf: *[40]u8) usize {
    if (n != n) { @memcpy(buf[0..3], "NaN"); return 3; }
    const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    if (n == inf) { @memcpy(buf[0..8], "Infinity"); return 8; }
    if (n == -inf) { @memcpy(buf[0..9], "-Infinity"); return 9; }
    var o: usize = 0;
    var v = n;
    if (v < 0) { buf[0] = '-'; o = 1; v = -v; }
    const int_part: u64 = if (v < 1.8446744073709552e19) @intFromFloat(@floor(v)) else 0;
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var t = int_part;
    if (t == 0) { digits[0] = '0'; d = 1; } else while (t > 0) : (d += 1) { digits[d] = @intCast((t % 10) + '0'); t /= 10; }
    var i: usize = 0;
    while (i < d) : (i += 1) { buf[o] = digits[d - 1 - i]; o += 1; }
    // Fractional part (up to 6 digits) — BotGuard rarely stringifies fractionals.
    var frac = v - @floor(v);
    if (frac > 0.0000001 and o + 8 < buf.len) {
        buf[o] = '.'; o += 1;
        var fd: usize = 0;
        while (fd < 6 and frac > 0.0000001) : (fd += 1) {
            frac *= 10;
            const dig: u8 = @intFromFloat(@floor(frac));
            buf[o] = dig + '0'; o += 1;
            frac -= @floor(frac);
        }
    }
    return o;
}

pub fn keyToNameIdx(key: Value) u32 { return keyNameIdx(key); }
fn keyNameIdx(key: Value) u32 {
    switch (key.tag) {
        .string => return key.data.str_idx,
        .number => {
            var buf: [40]u8 = undefined;
            const n = numberToDecimal(key.data.number, &buf);
            return values.internString(buf[0..n]);
        },
        .boolean => return values.internString(if (key.data.boolean != 0) "true" else "false"),
        .null_val => return values.internString("null"),
        .undefined => return values.internString("undefined"),
        .object, .array, .function => {
            // ToPropertyKey uses ToPrimitive with the string hint: toString
            // precedes valueOf, and a returned object tries the next method.
            if (invoke_callback) |invoke| {
                for ([_][]const u8{ "toString", "valueOf" }) |method| {
                    const fn_val = objects.getProperty(key.data.obj_idx, values.internString(method));
                    if (fn_val.tag != .function) continue;
                    const result = invoke(fn_val, key, &.{});
                    if (result.tag != .object and result.tag != .array and result.tag != .function) return keyNameIdx(result);
                }
            }
            requestNativeThrow("Cannot convert object to primitive value");
            return values.internString("");
        },
        else => return values.internString(""),
    }
}

/// Object.prototype.hasOwnProperty.call(obj, key) — args[0]=receiver, args[1]=key.
fn objHasOwn(args: []const Value) Value {
    if (args.len < 1) return Value.FALSE;
    const recv = args[0];
    const key = if (args.len >= 2) args[1] else Value.UNDEFINED;
    const name_idx = keyNameIdx(key);
    if (recv.tag == .string) {
        const name = values.getString(name_idx);
        if (eql(name, "length")) return Value.TRUE;
        if (objects.arrayIndexName(name)) |index| return boolVal(index < values.getStringLen(recv.data.str_idx));
        return Value.FALSE;
    }
    if (recv.tag != .object and recv.tag != .array and recv.tag != .function) return Value.FALSE;
    const oi: u32 = recv.data.obj_idx;
    if (objects.hasOwnProperty(oi, name_idx)) return Value.TRUE;
    if (recv.tag == .function) {
        const name = values.getString(name_idx);
        if (eql(name, "length") or eql(name, "name")) return Value.TRUE;
        const fid = objects.closureFuncId(oi);
        if (eql(name, "prototype") and fid < NATIVE_BASE) return boolVal(!compiler.getFunction(fid).is_arrow);
    }
    return Value.FALSE;
}

/// Object.prototype.isPrototypeOf.call(protoObj, obj) — is protoObj in obj's chain.
fn objIsPrototypeOf(args: []const Value) Value {
    if (args.len < 2) return Value.FALSE;
    const proto = args[0];
    const obj = args[1];
    if ((proto.tag != .object and proto.tag != .array and proto.tag != .function) or
        (obj.tag != .object and obj.tag != .array and obj.tag != .function)) return Value.FALSE;
    const proto_idx: u32 = proto.data.obj_idx;
    var cur = objects.getObjectPrototypeIdx(obj.data.obj_idx);
    var depth: u8 = 0;
    while (cur != objects.NULL_OBJ and depth < 64) : (depth += 1) {
        if (cur == proto_idx) return Value.TRUE;
        cur = objects.getObjectPrototypeIdx(cur);
    }
    return Value.FALSE;
}

/// Object.prototype.propertyIsEnumerable.call(obj, key) — own + enumerable.
fn objPropertyIsEnumerable(args: []const Value) Value {
    if (args.len < 1) return Value.FALSE;
    const recv = args[0];
    const name_idx = keyNameIdx(if (args.len >= 2) args[1] else Value.UNDEFINED);
    if (recv.tag == .string) {
        if (objects.arrayIndexName(values.getString(name_idx))) |index| return boolVal(index < values.getStringLen(recv.data.str_idx));
        return Value.FALSE;
    }
    if (recv.tag != .object and recv.tag != .array and recv.tag != .function) return Value.FALSE;
    return boolVal(objects.isOwnEnumerable(recv.data.obj_idx, name_idx));
}

/// BotGuard vmSetupCallback: the VM calls this with its four function values
/// (asyncSnapshotFunction, shutdownFunction, passEventFunction, checkCameraFunction).
/// We capture them so the host can drive snapshot() afterward.
pub var bg_dbg_setup_argc: u8 = 0;
pub var bg_dbg_setup_tags: [8]u8 = undefined;
fn bgVmSetup(args: []const Value) Value {
    if (args.len > 0) bg_async_snapshot_fn = args[0];
    if (args.len > 1) bg_shutdown_fn = args[1];
    if (args.len > 2) bg_pass_event_fn = args[2];
    if (args.len > 3) bg_check_camera_fn = args[3];
    bg_vm_setup_called = true;
    bg_dbg_setup_argc = @intCast(@min(args.len, 8));
    for (0..bg_dbg_setup_argc) |i| bg_dbg_setup_tags[i] = @intFromEnum(args[i].tag);
    return Value.UNDEFINED;
}

/// BotGuard snapshot result callback: the VM calls this with the base64
/// botguardResponse string once the snapshot completes.
fn bgSnapshotResult(args: []const Value) Value {
    if (args.len > 0) bg_snapshot_response = args[0];
    bg_snapshot_result_called = true;
    return Value.UNDEFINED;
}

// ── Math implementations ──

fn mathFloor(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    // @floor operates directly on f64 (handles NaN/Infinity/huge without the
    // panic that @intFromFloat would raise on out-of-i64-range values).
    return Value.number(@floor(args[0].toNumber()));
}

fn mathCeil(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    return Value.number(@ceil(args[0].toNumber()));
}

fn mathRound(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    // JS Math.round: floor(n + 0.5). @floor keeps NaN/Infinity safe.
    return Value.number(@floor(args[0].toNumber() + 0.5));
}

fn mathAbs(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const n = args[0].toNumber();
    return Value.number(if (n < 0) -n else n);
}

fn mathMin(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF0000000000000)))); // +Infinity
    var min = args[0].toNumber();
    for (args[1..]) |a| { const v = a.toNumber(); if (v < min) min = v; }
    return Value.number(min);
}

fn mathMax(args: []const Value) Value {
    if (args.len == 0) return Value.number(-@as(f64, @bitCast(@as(u64, 0x7FF0000000000000)))); // -Infinity
    var max = args[0].toNumber();
    for (args[1..]) |a| { const v = a.toNumber(); if (v > max) max = v; }
    return Value.number(max);
}

fn mathRandom() Value {
    // xorshift64
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    const bits = rng_state & 0x1FFFFFFFFFFFFF; // 53 bits
    return Value.number(@as(f64, @floatFromInt(bits)) / 9007199254740992.0);
}

fn mathPowN(args: []const Value) Value {
    if (args.len < 2) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const base = args[0].toNumber();
    const exp = args[1].toNumber();
    // Simple integer power
    if (exp == 0) return Value.number(1);
    if (exp == 1) return Value.number(base);
    if (exp == 2) return Value.number(base * base);
    var result: f64 = 1;
    var e = if (exp < 0) -exp else exp;
    while (e >= 1) : (e -= 1) result *= base;
    return Value.number(if (exp < 0) 1.0 / result else result);
}

fn mathLog(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    // Approximate natural log via series (sufficient for BG)
    const x = args[0].toNumber();
    if (x <= 0) return Value.number(-@as(f64, @bitCast(@as(u64, 0x7FF0000000000000))));
    // Use: ln(x) ≈ 2 * atanh((x-1)/(x+1)) series
    const y = (x - 1.0) / (x + 1.0);
    const y2 = y * y;
    var sum = y;
    var term = y;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        term *= y2;
        sum += term / @as(f64, @floatFromInt(2 * i + 3));
    }
    return Value.number(2.0 * sum);
}

fn mathSqrt(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const x = args[0].toNumber();
    if (x < 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    if (x == 0) return Value.number(0);
    // Newton's method
    var guess = x / 2.0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        guess = (guess + x / guess) / 2.0;
    }
    return Value.number(guess);
}

fn mathSign(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const n = args[0].toNumber();
    if (n > 0) return Value.number(1);
    if (n < 0) return Value.number(-1);
    return Value.number(0);
}

fn mathTrunc(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    // @trunc handles NaN/Infinity/huge safely (returns them unchanged / no panic).
    return Value.number(@trunc(args[0].toNumber()));
}

/// JS ToUint32: NaN/Infinity -> 0, else truncate toward zero mod 2^32. No panic.
fn nToU32(n: f64) u32 {
    if (n != n) return 0;
    const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    if (n == inf or n == -inf) return 0;
    var t = if (n < 0) @ceil(n) else @floor(n);
    const two32 = 4294967296.0;
    t = @mod(t, two32);
    if (t < 0) t += two32;
    if (t < 0 or t >= two32) return 0;
    return @intFromFloat(t);
}

fn mathClz32(args: []const Value) Value {
    if (args.len == 0) return Value.number(32);
    const n: u32 = nToU32(args[0].toNumber());
    if (n == 0) return Value.number(32);
    var count: f64 = 0;
    var v = n;
    while (v & 0x80000000 == 0) : (v <<= 1) count += 1;
    return Value.number(count);
}

fn mathImul(args: []const Value) Value {
    if (args.len < 2) return Value.number(0);
    const a: i32 = @bitCast(nToU32(args[0].toNumber()));
    const b: i32 = @bitCast(nToU32(args[1].toNumber()));
    const result: i64 = @as(i64, a) * @as(i64, b);
    const truncated: i32 = @truncate(result);
    return Value.number(@floatFromInt(truncated));
}

// ── Object static methods ──
// These are invoked as `Object.method(...)` (method call), so args[0] is the
// `Object` receiver and the real arguments start at args[1].

pub var dbg_objcreate_calls: u32 = 0;
pub var dbg_objcreate_protoobj: u32 = 0; // calls with an object prototype arg
pub var dbg_objcreate_undef: u32 = 0;    // calls with undefined/missing proto arg
pub var dbg_objcreate_proto: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_objcreate_proto_cnt: [16]u32 = [_]u32{0} ** 16;
pub var dbg_objcreate_proto_n: usize = 0;
fn objCreate(args: []const Value) Value {
    dbg_objcreate_calls += 1;
    if (args.len >= 2 and (args[1].tag == .object or args[1].tag == .array or args[1].tag == .function)) {
        dbg_objcreate_protoobj += 1;
        const pidx: u32 = args[1].data.obj_idx;
        var seen = false;
        var i: usize = 0;
        while (i < dbg_objcreate_proto_n) : (i += 1) { if (dbg_objcreate_proto[i] == pidx) { dbg_objcreate_proto_cnt[i] += 1; seen = true; break; } }
        if (!seen and dbg_objcreate_proto_n < dbg_objcreate_proto.len) { dbg_objcreate_proto[dbg_objcreate_proto_n] = pidx; dbg_objcreate_proto_cnt[dbg_objcreate_proto_n] = 1; dbg_objcreate_proto_n += 1; }
    } else dbg_objcreate_undef += 1;
    const o = objects.createObject();
    // Object.create(proto): set the new object's [[Prototype]].
    if (args.len >= 2 and (args[1].tag == .object or args[1].tag == .array or args[1].tag == .function)) {
        objects.setObjectPrototype(o, @intCast(args[1].data.obj_idx));
    } else if (args.len >= 2 and args[1].tag == .null_val) {
        // Object.create(null): no prototype.
        objects.setObjectPrototype(o, objects.NULL_OBJ);
    }
    // Object.create(proto, propsObject): apply the property descriptors. Each
    // own key of propsObject maps to a descriptor with `value` or `get`.
    // BotGuard's TK does `Object.create(D.Oh, {value:{value:{}}})`; without
    // honoring this second arg the created object is missing properties that
    // are read (then `.prototype`-accessed) later, yielding undefined.
    if (args.len >= 3 and (args[2].tag == .object or args[2].tag == .array)) {
        const props: u32 = args[2].data.obj_idx;
        applyPropertyDescriptors(o, props);
    }
    return Value.object(o);
}

/// Apply a `{ key: descriptor, ... }` property-descriptor bag onto `target`.
/// Used by Object.create(proto, props) and Object.defineProperties.
fn applyPropertyDescriptors(target: u32, props: u32) void {
    const pc = objects.ownPropCount(props);
    var i: u16 = 0;
    while (i < pc) : (i += 1) {
        const key_idx = objects.ownPropNameAt(props, i);
        const desc = objects.getProperty(props, key_idx);
        if (desc.tag != .object and desc.tag != .array) continue;
        const dobj: u32 = desc.data.obj_idx;
        const val = objects.getProperty(dobj, values.internString("value"));
        if (val.tag != .undefined) {
            objects.setProperty(target, key_idx, val);
        } else {
            const getter = objects.getProperty(dobj, values.internString("get"));
            if (getter.tag == .function) objects.setGetterProperty(target, key_idx, getter);
        }
    }
}

fn objGetProto(args: []const Value) Value {
    if (args.len >= 2 and (args[1].tag == .object or args[1].tag == .array or args[1].tag == .function)) {
        const p = objects.getObjectPrototypeIdx(@intCast(args[1].data.obj_idx));
        if (p != objects.NULL_OBJ) return Value.object(p);
    }
    return Value.NULL;
}

/// Object.defineProperty(obj, key, descriptor). BotGuard uses this to install
/// methods/values. Preserve omitted attributes on an existing data property;
/// new properties use the descriptor defaults. Getter reads remain lazy.
fn objGetOwnDescriptor(args: []const Value) Value {
    if (args.len < 3) return Value.UNDEFINED;
    const target = args[1];
    if (target.tag != .object and target.tag != .array and target.tag != .function) return Value.UNDEFINED;
    const key = if (args[2].tag == .string) args[2].data.str_idx else valueToStrIdx(args[2]);
    var prop: objects.Property = undefined;
    if (!objects.ownPropertyDescriptor(target.data.obj_idx, key, &prop)) return Value.UNDEFINED;
    const desc = objects.createObject();
    if (prop.flags.is_getter or prop.flags.is_setter) {
        objects.setProperty(desc, values.internString("get"), if (prop.flags.is_getter) prop.value else Value.UNDEFINED);
        objects.setProperty(desc, values.internString("set"), if (prop.flags.is_setter) prop.value else Value.UNDEFINED);
    } else {
        objects.setProperty(desc, values.internString("value"), prop.value);
        objects.setProperty(desc, values.internString("writable"), if (prop.flags.writable) Value.TRUE else Value.FALSE);
    }
    objects.setProperty(desc, values.internString("enumerable"), if (prop.flags.enumerable) Value.TRUE else Value.FALSE);
    objects.setProperty(desc, values.internString("configurable"), if (prop.flags.configurable) Value.TRUE else Value.FALSE);
    return Value.object(desc);
}

fn objDefineProperty(args: []const Value) Value {
    if (args.len < 4) return if (args.len >= 2) args[1] else Value.UNDEFINED;
    const target = args[1];
    const key = args[2];
    const desc = args[3];
    if (target.tag != .object and target.tag != .array and target.tag != .function) return target;
    if (desc.tag != .object) return target;
    const tobj: u32 = target.data.obj_idx;
    const dobj: u32 = desc.data.obj_idx;
    // key -> string index
    const key_idx: u32 = if (key.tag == .string) key.data.str_idx else valueToStrIdx(key);
    const existed = objects.hasOwnProperty(tobj, key_idx);
    const value_key = values.internString("value");
    if (objects.hasOwnProperty(dobj, value_key)) {
        objects.setProperty(tobj, key_idx, objects.getProperty(dobj, value_key));
    } else {
        const getter = objects.getProperty(dobj, values.internString("get"));
        if (getter.tag == .function) {
            // Accessor property: mark is_getter so reads invoke the getter.
            objects.setGetterProperty(tobj, key_idx, getter);
        } else if (!existed) {
            objects.setProperty(tobj, key_idx, Value.UNDEFINED);
        }
    }
    const enumerable_key = values.internString("enumerable");
    if (!existed or objects.hasOwnProperty(dobj, enumerable_key))
        objects.setEnumerable(tobj, key_idx, objects.getProperty(dobj, enumerable_key).isTruthy());
    const writable_key = values.internString("writable");
    if (!existed or objects.hasOwnProperty(dobj, writable_key))
        objects.setWritable(tobj, key_idx, objects.getProperty(dobj, writable_key).isTruthy());
    return target;
}

/// Minimal value->string-index for property keys (numbers/strings).
fn valueToStrIdx(v: Value) u32 {
    if (v.tag == .string) return v.data.str_idx;
    if (v.tag == .number) {
        var b: [32]u8 = undefined;
        const n = numToDecimal(v.data.number, &b);
        return values.internString(b[0..n]);
    }
    return values.internString("");
}

fn numToDecimal(n: f64, buf: []u8) usize {
    const i = toI64(n);
    if (i == 0) { buf[0] = '0'; return 1; }
    var neg = false; var u: u64 = undefined;
    if (i < 0) { neg = true; u = @intCast(-i); } else { u = @intCast(i); }
    var d: [20]u8 = undefined; var dn: usize = 0;
    while (u > 0) : (u /= 10) { d[dn] = @intCast((u % 10) + '0'); dn += 1; }
    var o: usize = 0;
    if (neg) { buf[0] = '-'; o = 1; }
    var k: usize = 0;
    while (k < dn) : (k += 1) buf[o + k] = d[dn - 1 - k];
    return o + dn;
}

// ── DOM element stub ──

/// document.createElement(tag) -> a generic element object with the common
/// methods/props BotGuard touches (style, setAttribute, appendChild, and — for
/// canvas — getContext). Matches the minimal element that lets BotGuard run its
/// success path (verified against the Node reference).
fn makeDomElement() Value {
    const el = objects.createObject();
    const style = objects.createObject();
    objects.setProperty(el, values.internString("style"), Value.object(style));
    installNativeMethod(el, "setAttribute", N_DOM_NOOP);
    installNativeMethod(el, "getAttribute", N_DOM_NOOP);
    installNativeMethod(el, "removeAttribute", N_DOM_NOOP);
    installNativeMethod(el, "appendChild", N_DOM_NOOP);
    installNativeMethod(el, "removeChild", N_DOM_NOOP);
    installNativeMethod(el, "addEventListener", N_DOM_NOOP);
    installNativeMethod(el, "removeEventListener", N_DOM_NOOP);
    // Fresh detached elements have callable focus/blur methods, but no active
    // document focus or layout box. Their scroll extents start at zero.
    installNativeMethod(el, "focus", N_DOM_NOOP);
    installNativeMethod(el, "blur", N_DOM_NOOP);
    installNativeMethod(el, "getContext", N_DOM_GET_CONTEXT);
    installNativeMethod(el, "toDataURL", N_DOM_NOOP);
    objects.setProperty(el, values.internString("width"), Value.number(0));
    objects.setProperty(el, values.internString("height"), Value.number(0));
    objects.setProperty(el, values.internString("scrollWidth"), Value.number(0));
    objects.setProperty(el, values.internString("scrollHeight"), Value.number(0));
    // iframe realm access: BotGuard creates an iframe and reads
    // `iframe.contentWindow` to get a fresh realm's pristine `String`/`eval`
    // (anti-tamper). jsdom returns a real Window; we return the global object
    // (which carries String/Object/eval/etc.). Also expose contentDocument.
    if (g_global_obj != 0) {
        objects.setProperty(el, values.internString("contentWindow"), Value.object(g_global_obj));
        const doc = objects.getProperty(g_global_obj, values.internString("document"));
        objects.setProperty(el, values.internString("contentDocument"), doc);
    }
    return Value.object(el);
}

/// trustedTypes.createPolicy(name, rules) -> a policy object whose
/// createHTML/createScript/createScriptURL are PASSTHROUGH (return the input
/// string unchanged). BotGuard's `fA` wraps its eval source via
/// `policy.createScript(src)`; a no-op that returned undefined truncated the
/// eval argument (SyntaxError "Unexpected end of input"). A passthrough policy
/// makes createScript(src) === src, matching a browser's TrustedTypes.
fn makeTrustedTypesPolicy() Value {
    const p = objects.createObject();
    installNativeMethod(p, "createHTML", N_TT_IDENTITY);
    installNativeMethod(p, "createScript", N_TT_IDENTITY);
    installNativeMethod(p, "createScriptURL", N_TT_IDENTITY);
    objects.setProperty(p, values.internString("name"), Value.string(values.internString("default")));
    return Value.object(p);
}

/// policy.createScript(s) / createHTML(s) -> s. Called as a method so the
/// receiver (policy) is prepended; the actual input is the LAST argument. The
/// return should coerce to the input string when used in string contexts and
/// compare ===1 when the input is "1" (BotGuard's fA probe `createScript("1")`
/// then does `b.eval(that)===1`), so returning the raw string is correct.
pub var dbg_tt_watch: bool = false;
pub var dbg_tt_done: bool = false;
pub var dbg_tt_argtag: u8 = 255;
pub var dbg_tt_argfunc: u16 = 0xFFFF;
pub fn dbgTtEnable() void { dbg_tt_watch = true; dbg_tt_done = false; }
pub fn dbgTtArgTag() u8 { return dbg_tt_argtag; }
pub fn dbgTtArgFunc() u16 { return dbg_tt_argfunc; }
/// Function.prototype.toString: return the function's SOURCE TEXT. Receiver is
/// args[0] under the method-call convention. BotGuard self-rehydrates functions
/// via `eval("NAME="+fn)` — this MUST return the real source. Native/bound
/// functions (no stored source) return the standard "{ [native code] }" form.
fn fnToStringNative(args: []const Value) Value {
    if (args.len == 0 or args[0].tag != .function) {
        return Value.string(values.internString("function () { [native code] }"));
    }
    const fid = objects.closureFuncId(args[0].data.obj_idx);
    if (fid != 0xFFFF) {
        const src = compiler.funcSourceText(fid);
        if (src.len > 0 and (src[0] == 'f' or src[0] == '(' or src[0] == 'a')) {
            return Value.string(values.internString(src));
        }
    }
    return Value.string(values.internString("function () { [native code] }"));
}
fn ttIdentity(args: []const Value) Value {
    // DIAGNOSTIC: capture the arg type of the first createScript/identity call
    // whose last non-receiver arg is a FUNCTION (the `fA(fn)` self-eval path).
    if (dbg_tt_watch and !dbg_tt_done and args.len >= 2) {
        const last = args[args.len - 1];
        if (last.tag == .function or last.tag == .object or last.tag == .array) {
            dbg_tt_done = true;
            dbg_tt_argtag = @intFromEnum(last.tag);
            dbg_tt_argfunc = if (last.tag == .function) objects.closureFuncId(last.data.obj_idx) else 0xFFFF;
        }
    }
    // Find the last string argument (skip the prepended receiver).
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        if (args[i].tag == .string) return args[i];
    }
    return Value.string(values.internString(""));
}

// ── Error constructors ──

/// Build an Error-like object { name, message } with the shared error proto.
/// args[0] is the message (when called as Error(msg) or via .call the receiver
/// is prepended, so we take the LAST string arg as the message).
fn makeErrorVal(name: []const u8, args: []const Value) Value {
    // Find a string argument to use as the message (skip a non-string receiver
    // when called via .call, and skip the name we set below).
    var msg_idx: u32 = values.internString("");
    for (args) |a| {
        if (a.tag == .string) { msg_idx = a.data.str_idx; }
    }
    const name_idx = values.internString(name);
    const o = objects.createObject();
    objects.setObjectPrototype(o, objects.getErrorProto());
    objects.setProperty(o, values.internString("name"), Value.string(name_idx));
    objects.setProperty(o, values.internString("message"), Value.string(msg_idx));
    return Value.object(o);
}

/// Error.prototype.toString -> "name: message" (receiver is args[0]).
fn errorToString(args: []const Value) Value {
    if (args.len == 0 or (args[0].tag != .object and args[0].tag != .array)) {
        return Value.string(values.internString("Error"));
    }
    const o: u32 = args[0].data.obj_idx;
    const nm = objects.getProperty(o, values.internString("name"));
    const ms = objects.getProperty(o, values.internString("message"));
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    const name_s = if (nm.tag == .string) values.getString(nm.data.str_idx) else "Error";
    const msg_s = if (ms.tag == .string) values.getString(ms.data.str_idx) else "";
    const nl = @min(name_s.len, buf.len);
    @memcpy(buf[0..nl], name_s[0..nl]); n = nl;
    if (msg_s.len > 0 and n + 2 < buf.len) {
        buf[n] = ':'; buf[n + 1] = ' '; n += 2;
        const ml = @min(msg_s.len, buf.len - n);
        @memcpy(buf[n .. n + ml], msg_s[0..ml]); n += ml;
    }
    return Value.string(values.internString(buf[0..n]));
}

// ── String implementations ──

/// Safe JS ToUint16 (for String.fromCharCode): NaN/Infinity/out-of-range -> 0,
/// otherwise truncate toward zero and take modulo 2^16. Never panics.
fn toU16(n: f64) u16 {
    if (n != n) return 0; // NaN
    const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    if (n == inf or n == -inf) return 0;
    var t = if (n < 0) @ceil(n) else @floor(n);
    const two16 = 65536.0;
    t = @mod(t, two16);
    if (t < 0) t += two16;
    if (t < 0 or t >= two16) return 0;
    return @intFromFloat(t);
}

/// Safe non-negative array/string index: NaN/negative/huge -> 0 (bounds are
/// checked by callers). Never panics on @intFromFloat.
fn safeIndex(n: f64) usize {
    if (n != n or n <= 0) return 0;
    if (n >= 4294967295.0) return 0xFFFFFFFF;
    return @intFromFloat(@floor(n));
}

/// Safe f64 -> i64 (for substring/slice offsets): NaN -> 0, clamp to a large
/// finite range so @intFromFloat never panics on Infinity/huge magnitudes.
fn toI64(n: f64) i64 {
    if (n != n) return 0; // NaN
    if (n >= 9.007199254740992e15) return 9007199254740992;
    if (n <= -9.007199254740992e15) return -9007199254740992;
    return @intFromFloat(@trunc(n));
}

var fromcharcode_buf: [16384]u8 = undefined;
fn strFromCharCode(args: []const Value) Value {
    const buf = &fromcharcode_buf;
    var len: usize = 0;
    // When invoked via `.call`/`.apply` the receiver is prepended as args[0];
    // for the common static call String.fromCharCode(a,b,...) every arg is a
    // char code. We treat all numeric args as codes; a non-numeric leading
    // receiver (String function/undefined) yields code 0 which we skip below
    // only if it's the receiver — but since BotGuard calls it plainly, just
    // encode each arg's ToUint16 as a byte (low 8 bits; BotGuard uses ASCII).
    for (args) |a| {
        if (a.tag != .number) continue; // skip non-numeric (e.g. receiver)
        const code = toU16(a.toNumber());
        if (len < buf.len) { buf[len] = @intCast(code & 0xFF); len += 1; }
    }
    return Value.string(values.internString(buf[0..len]));
}

fn strCharAt(args: []const Value) Value {
    if (args.len < 2) return Value.string(values.internString(""));
    if (args[0].tag != .string) return Value.string(values.internString(""));
    const str = values.getString(args[0].data.str_idx);
    const idx: usize = safeIndex(args[1].toNumber());
    if (idx >= str.len) return Value.string(values.internString(""));
    return Value.string(values.internString(str[idx .. idx + 1]));
}

pub var dbg_source_n: usize = 0;
pub var dbg_source_strings: [256]u32 = undefined;
fn strCharCodeAt(args: []const Value) Value {
    if (args.len < 2) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const idx: usize = if (args.len > 1) safeIndex(args[1].toNumber()) else 0;
    if (idx == 0 and str.len >= 8 and dbg_source_n < 256) {
        dbg_source_strings[dbg_source_n] = args[0].data.str_idx;
        dbg_source_n += 1;
    }
    if (idx >= str.len) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    return Value.number(@floatFromInt(str[idx]));
}

fn strIndexOf(args: []const Value) Value {
    if (args.len < 2) return Value.number(-1);
    const haystack = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const needle = values.getString(if (args[1].tag == .string) args[1].data.str_idx else 0);
    if (needle.len == 0) return Value.number(0);
    if (needle.len > haystack.len) return Value.number(-1);
    for (0..haystack.len - needle.len + 1) |i| {
        if (eql(haystack[i .. i + needle.len], needle)) return Value.number(@floatFromInt(i));
    }
    return Value.number(-1);
}

fn strSlice(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const len_i: i64 = @intCast(str.len);
    var start: i64 = if (args.len > 1) toI64(args[1].toNumber()) else 0;
    var end: i64 = if (args.len > 2) toI64(args[2].toNumber()) else len_i;
    if (start < 0) start = @max(len_i + start, 0);
    if (end < 0) end = @max(len_i + end, 0);
    if (start >= len_i or start >= end) return Value.string(values.internString(""));
    const s: usize = @intCast(@min(start, len_i));
    const e: usize = @intCast(@min(end, len_i));
    return Value.string(values.internString(str[s..e]));
}

fn strSplit(args: []const Value) Value {
    if (args.len == 0 or args[0].tag == .null_val or args[0].tag == .undefined) {
        requestNativeThrow("String.split requires a non-null receiver"); return Value.UNDEFINED;
    }
    const text_val = stringCtor(args[0..1]); const text = values.getString(text_val.data.str_idx);
    const separator = if (args.len > 1) args[1] else Value.UNDEFINED;
    const limit: u32 = if (args.len > 2 and args[2].tag != .undefined) splitLimit(args[2].toNumber()) else 0xFFFFFFFF;
    const arr = objects.createArray(0);
    if (limit == 0) return Value.object(arr);
    if (separator.tag == .undefined) { objects.arrayPush(arr, text_val); return Value.object(arr); }
    if (!isRegexp(separator)) {
        const needle = values.getString(stringCtor(&.{separator}).data.str_idx);
        if (needle.len == 0) {
            for (0..@min(text.len, limit)) |i| objects.arrayPush(arr, Value.string(values.internString(text[i..][0..1])));
            return Value.object(arr);
        }
        var from: usize = 0; var scan: usize = 0;
        while (scan <= text.len and objects.arrayLength(arr) < limit) : (scan += 1) {
            if (needle.len > text.len - scan or !eql(text[scan..][0..needle.len], needle)) continue;
            objects.arrayPush(arr, Value.string(values.internString(text[from..scan])));
            scan += needle.len; from = scan;
            if (objects.arrayLength(arr) == limit) return Value.object(arr);
            // The loop increment should not skip an adjacent separator.
            if (scan > 0) scan -= 1;
        }
        objects.arrayPush(arr, Value.string(values.internString(text[from..])));
        return Value.object(arr);
    }
    var flags = regexpFlags(separator) orelse return Value.UNDEFINED;
    // split searches a cloned pattern; the original lastIndex is untouched.
    flags.global = false; flags.sticky = false;
    if (!regexp.compileFlags(regexpPattern(separator), flags)) { requestNativeThrow("Unsupported regular expression"); return Value.UNDEFINED; }
    if (text.len == 0) {
        if (!regexp.exec(text).matched) objects.arrayPush(arr, text_val);
        return Value.object(arr);
    }
    var from: usize = 0; var scan: usize = 0;
    while (scan < text.len) {
        const m = regexp.execFrom(text, scan);
        if (m.exhausted) { requestNativeThrow("Regular expression execution limit exceeded"); return Value.UNDEFINED; }
        if (!m.matched or m.start == text.len) break;
        const end: usize = m.start + m.len;
        if (end == from) { scan = end + 1; continue; }
        objects.arrayPush(arr, Value.string(values.internString(text[from..m.start])));
        if (objects.arrayLength(arr) == limit) return Value.object(arr);
        for (0..m.n_captures) |i| {
            objects.arrayPush(arr, captureValue(text, m.captures[i]));
            if (objects.arrayLength(arr) == limit) return Value.object(arr);
        }
        from = end; scan = end;
    }
    if (objects.arrayLength(arr) < limit) objects.arrayPush(arr, Value.string(values.internString(text[from..])));
    return Value.object(arr);
}

fn splitLimit(n: f64) u32 {
    const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    if (n != n or n == inf or n == -inf or n == 0) return 0;
    return @intFromFloat(@mod(@trunc(n), 4294967296.0));
}

fn strReplace(args: []const Value) Value {
    if (args.len == 0 or args[0].tag == .null_val or args[0].tag == .undefined) {
        requestNativeThrow("String.replace requires a non-null receiver"); return Value.UNDEFINED;
    }
    const text_val = stringCtor(args[0..1]); const text = values.getString(text_val.data.str_idx);
    const search_value = if (args.len > 1) args[1] else Value.UNDEFINED;
    const replace_value = if (args.len > 2) args[2] else Value.UNDEFINED;
    const is_regex = isRegexp(search_value);
    const pattern = if (is_regex) regexpPattern(search_value) else values.getString(stringCtor(&.{search_value}).data.str_idx);
    const flags = if (is_regex) regexpFlags(search_value) orelse return Value.UNDEFINED else regexp.Flags{};
    const replacement = if (replace_value.tag == .function) "" else values.getString(stringCtor(&.{replace_value}).data.str_idx);
    var scan: usize = if (is_regex and flags.sticky and !flags.global) regexpLastIndex(search_value, text.len) else 0;
    var matches: [1024]regexp.Match = undefined; var count: usize = 0;
    if (is_regex) {
        if (flags.global) setRegexpLastIndex(search_value, 0);
        if (!regexp.compileFlags(pattern, flags)) { requestNativeThrow("Unsupported regular expression"); return Value.UNDEFINED; }
    }
    // Collect matches before invoking replacement callbacks, as JavaScript does.
    // A callback can change lastIndex or compile another regex without affecting
    // the already selected matches, and observes the completed search's state.
    while (scan <= text.len) {
        var m = regexp.Match{};
        if (is_regex) m = regexp.execFrom(text, scan) else {
            var at = scan;
            while (at <= text.len) : (at += 1) {
                if (pattern.len <= text.len - at and eql(text[at..][0..pattern.len], pattern)) {
                    m = .{ .matched = true, .start = @intCast(at), .len = @intCast(pattern.len) }; break;
                }
            }
        }
        if (m.exhausted) { requestNativeThrow("Regular expression execution limit exceeded"); return Value.UNDEFINED; }
        if (!m.matched) { if (is_regex and flags.sticky) setRegexpLastIndex(search_value, 0); break; }
        if (count == matches.len) { requestNativeThrow("Replacement match capacity exceeded"); return Value.UNDEFINED; }
        matches[count] = m; count += 1;
        const end: usize = m.start + m.len;
        if (is_regex and flags.sticky) setRegexpLastIndex(search_value, end);
        if (!is_regex or !flags.global) break;
        scan = end + @intFromBool(m.len == 0);
    }
    if (is_regex and flags.global) setRegexpLastIndex(search_value, 0);
    var copied: usize = 0; var used: usize = 0; var buf: [65535]u8 = undefined;
    for (matches[0..count]) |m| {
        const start: usize = m.start; const end = start + m.len;
        if (!replaceAppend(&buf, &used, text[copied..start])) return replaceOverflow();
        if (replace_value.tag == .function) {
            const callback = invoke_callback orelse { requestNativeThrow("Replacement callback requires the interpreter"); return Value.UNDEFINED; };
            var callback_args: [regexp.MAX_CAPTURES + 3]Value = undefined;
            callback_args[0] = Value.string(values.internString(text[start..end]));
            for (0..m.n_captures) |n| callback_args[n + 1] = captureValue(text, m.captures[n]);
            callback_args[m.n_captures + 1] = Value.number(@floatFromInt(start));
            callback_args[m.n_captures + 2] = text_val;
            const result = callback(replace_value, Value.UNDEFINED, callback_args[0..m.n_captures + 3]);
            const literal = values.getString(stringCtor(&.{result}).data.str_idx);
            if (!replaceAppend(&buf, &used, literal)) return replaceOverflow();
        } else if (!replaceSubstitution(&buf, &used, text, replacement, m)) return replaceOverflow();
        copied = end;
    }
    if (!replaceAppend(&buf, &used, text[copied..])) return replaceOverflow();
    return Value.string(values.internString(buf[0..used]));
}
fn replaceOverflow() Value { requestNativeThrow("String replacement exceeds fixed string capacity"); return Value.UNDEFINED; }
fn replaceSubstitution(buf: []u8, used: *usize, text: []const u8, replacement: []const u8, m: regexp.Match) bool {
    const start: usize = m.start; const end = start + m.len;
    var i: usize = 0;
    while (i < replacement.len) : (i += 1) {
        if (replacement[i] == '$' and i + 1 < replacement.len) {
            const next = replacement[i + 1];
            const part: ?[]const u8 = switch (next) {
                '$' => "$", '&' => text[start..end], '`' => text[0..start], '\'' => text[end..], else => null,
            };
            if (part) |p| { if (!replaceAppend(buf, used, p)) return false; i += 1; continue; }
            if (next >= '0' and next <= '9') {
                var n: usize = next - '0'; var consumed: usize = 1;
                if (i + 2 < replacement.len and replacement[i + 2] >= '0' and replacement[i + 2] <= '9') {
                    const two = n * 10 + replacement[i + 2] - '0';
                    if (two > 0 and two <= m.n_captures) { n = two; consumed = 2; }
                }
                if (n > 0 and n <= m.n_captures) {
                    const capture = m.captures[n - 1];
                    if (capture.matched and !replaceAppend(buf, used, text[capture.start..][0..capture.len])) return false;
                    i += consumed; continue;
                }
            }
        }
        if (!replaceAppend(buf, used, replacement[i..][0..1])) return false;
    }
    return true;
}

fn isRegexp(v: Value) bool { return v.tag == .object and objects.objTypeOf(v.data.obj_idx) == .regexp; }
fn regexpPattern(v: Value) []const u8 {
    const source = objects.getProperty(v.data.obj_idx, values.internString("source"));
    return if (source.tag == .string) values.getString(source.data.str_idx) else "";
}
fn regexpFlags(v: Value) ?regexp.Flags {
    const f = objects.getProperty(v.data.obj_idx, values.internString("flags"));
    return regexp.parseFlags(if (f.tag == .string) values.getString(f.data.str_idx) else "");
}
fn setRegexpLastIndex(v: Value, index: usize) void {
    objects.setProperty(v.data.obj_idx, values.internString("lastIndex"), Value.number(@floatFromInt(index)));
}
fn regexpLastIndex(v: Value, len: usize) usize {
    const n = objects.getProperty(v.data.obj_idx, values.internString("lastIndex")).toNumber();
    if (n != n or n <= 0) return 0;
    if (n > @as(f64, @floatFromInt(len))) return len + 1;
    return @intFromFloat(n);
}
fn regexpCtor(args: []const Value) Value {
    const first = if (args.len > 0) args[0] else Value.UNDEFINED;
    const flags_arg = if (args.len > 1) args[1] else Value.UNDEFINED;
    if (isRegexp(first) and flags_arg.tag == .undefined) return first;
    const pattern = if (isRegexp(first)) regexpPattern(first) else if (first.tag == .undefined) "" else values.getString(stringCtor(&.{first}).data.str_idx);
    const flag_text = if (flags_arg.tag != .undefined) values.getString(stringCtor(&.{flags_arg}).data.str_idx) else "";
    const flags = regexp.parseFlags(flag_text) orelse { requestNativeThrow("Invalid regular expression flags"); return Value.UNDEFINED; };
    if (!regexp.compileFlags(pattern, flags)) { requestNativeThrow("Unsupported regular expression"); return Value.UNDEFINED; }
    const obj = objects.createObject();
    if (obj == objects.NULL_OBJ) { requestNativeThrow("Regular expression object capacity exceeded"); return Value.UNDEFINED; }
    objects.getObject(obj).obj_type = .regexp;
    objects.setObjectPrototype(obj, regexp_proto);
    objects.setProperty(obj, values.internString("source"), Value.string(values.internString(if (pattern.len == 0) "(?:)" else pattern)));
    var canonical: [5]u8 = undefined; var n: usize = 0;
    if (flags.global) { canonical[n] = 'g'; n += 1; }
    if (flags.ignore_case) { canonical[n] = 'i'; n += 1; }
    if (flags.multiline) { canonical[n] = 'm'; n += 1; }
    if (flags.dot_all) { canonical[n] = 's'; n += 1; }
    if (flags.sticky) { canonical[n] = 'y'; n += 1; }
    objects.setProperty(obj, values.internString("flags"), Value.string(values.internString(canonical[0..n])));
    objects.setProperty(obj, values.internString("global"), boolVal(flags.global));
    objects.setProperty(obj, values.internString("ignoreCase"), boolVal(flags.ignore_case));
    objects.setProperty(obj, values.internString("multiline"), boolVal(flags.multiline));
    objects.setProperty(obj, values.internString("dotAll"), boolVal(flags.dot_all));
    objects.setProperty(obj, values.internString("sticky"), boolVal(flags.sticky));
    objects.setProperty(obj, values.internString("lastIndex"), Value.number(0));
    const names = [_][]const u8{ "source", "flags", "global", "ignoreCase", "multiline", "dotAll", "sticky", "lastIndex" };
    for (names) |name| objects.setEnumerable(obj, values.internString(name), false);
    return Value.object(obj);
}
fn captureValue(text: []const u8, capture: regexp.Capture) Value {
    return if (capture.matched) Value.string(values.internString(text[capture.start..][0..capture.len])) else Value.UNDEFINED;
}
fn matchArray(text_val: Value, match: regexp.Match) Value {
    const text = values.getString(text_val.data.str_idx);
    const arr = objects.createArray(0);
    objects.arrayPush(arr, Value.string(values.internString(text[match.start..][0..match.len])));
    for (0..match.n_captures) |i| objects.arrayPush(arr, captureValue(text, match.captures[i]));
    objects.setProperty(arr, values.internString("index"), Value.number(@floatFromInt(match.start)));
    objects.setProperty(arr, values.internString("input"), text_val);
    objects.setProperty(arr, values.internString("groups"), Value.UNDEFINED);
    return Value.object(arr);
}
fn regexpExec(args: []const Value, only_test: bool) Value {
    if (args.len == 0 or !isRegexp(args[0])) { requestNativeThrow("RegExp.exec requires a RegExp receiver"); return Value.UNDEFINED; }
    const recv = args[0];
    const text_val = stringCtor(&.{if (args.len > 1) args[1] else Value.UNDEFINED});
    const text = values.getString(text_val.data.str_idx);
    const flags = regexpFlags(recv) orelse return Value.UNDEFINED;
    const from = if (flags.global or flags.sticky) regexpLastIndex(recv, text.len) else 0;
    if (!regexp.compileFlags(regexpPattern(recv), flags)) { requestNativeThrow("Unsupported regular expression"); return Value.UNDEFINED; }
    const m = regexp.execFrom(text, from);
    if (m.exhausted) { requestNativeThrow("Regular expression execution limit exceeded"); return Value.UNDEFINED; }
    if (flags.global or flags.sticky) setRegexpLastIndex(recv, if (m.matched) m.start + m.len else 0);
    return if (only_test) boolVal(m.matched) else if (m.matched) matchArray(text_val, m) else Value.NULL;
}
fn regexpToString(args: []const Value) Value {
    if (args.len == 0 or !isRegexp(args[0])) { requestNativeThrow("RegExp.toString requires a RegExp receiver"); return Value.UNDEFINED; }
    const pattern = regexpPattern(args[0]);
    const flags = objects.getProperty(args[0].data.obj_idx, values.internString("flags"));
    const flag_text = if (flags.tag == .string) values.getString(flags.data.str_idx) else "";
    var buf: [regexp.MAX_PATTERN + 7]u8 = undefined; var used: usize = 0;
    if (!replaceAppend(&buf, &used, "/") or !replaceAppend(&buf, &used, pattern) or !replaceAppend(&buf, &used, "/") or !replaceAppend(&buf, &used, flag_text)) return Value.UNDEFINED;
    return Value.string(values.internString(buf[0..used]));
}
fn strMatch(args: []const Value) Value {
    if (args.len == 0 or args[0].tag == .null_val or args[0].tag == .undefined) { requestNativeThrow("String.match requires a non-null receiver"); return Value.UNDEFINED; }
    const text_val = stringCtor(args[0..1]);
    const operand = if (args.len > 1) args[1] else Value.UNDEFINED;
    const re = if (isRegexp(operand)) operand else regexpCtor(&.{operand});
    if (!isRegexp(re)) return Value.UNDEFINED;
    const flags = regexpFlags(re) orelse return Value.UNDEFINED;
    if (!flags.global) return regexpExec(&.{ re, text_val }, false);
    const text = values.getString(text_val.data.str_idx);
    setRegexpLastIndex(re, 0);
    if (!regexp.compileFlags(regexpPattern(re), flags)) { requestNativeThrow("Unsupported regular expression"); return Value.UNDEFINED; }
    const arr = objects.createArray(0); var from: usize = 0;
    while (from <= text.len) {
        const m = regexp.execFrom(text, from);
        if (m.exhausted) { requestNativeThrow("Regular expression execution limit exceeded"); return Value.UNDEFINED; }
        if (!m.matched) break;
        objects.arrayPush(arr, Value.string(values.internString(text[m.start..][0..m.len])));
        from = m.start + m.len + @intFromBool(m.len == 0);
    }
    setRegexpLastIndex(re, 0);
    return if (objects.arrayLength(arr) == 0) Value.NULL else Value.object(arr);
}

fn replaceAppend(buf: []u8, used: *usize, text: []const u8) bool {
    if (text.len > buf.len - used.*) return false;
    @memcpy(buf[used.*..][0..text.len], text); used.* += text.len;
    return true;
}

fn strTrim(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    var start: usize = 0;
    var end: usize = str.len;
    while (start < end and isWhitespace(str[start])) start += 1;
    while (end > start and isWhitespace(str[end - 1])) end -= 1;
    return Value.string(values.internString(str[start..end]));
}

fn strToLower(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    var buf: [1024]u8 = undefined;
    const len = @min(str.len, 1024);
    for (0..len) |i| {
        buf[i] = if (str[i] >= 'A' and str[i] <= 'Z') str[i] + 32 else str[i];
    }
    return Value.string(values.internString(buf[0..len]));
}

fn strToUpper(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    var buf: [1024]u8 = undefined;
    const len = @min(str.len, 1024);
    for (0..len) |i| {
        buf[i] = if (str[i] >= 'a' and str[i] <= 'z') str[i] - 32 else str[i];
    }
    return Value.string(values.internString(buf[0..len]));
}

fn strIncludes(args: []const Value) Value {
    const result = strIndexOf(args);
    return boolVal(result.data.number >= 0);
}

fn strStartsWith(args: []const Value) Value {
    if (args.len < 2) return Value.FALSE;
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const prefix = values.getString(if (args[1].tag == .string) args[1].data.str_idx else 0);
    if (prefix.len > str.len) return Value.FALSE;
    return boolVal(eql(str[0..prefix.len], prefix));
}

fn strEndsWith(args: []const Value) Value {
    if (args.len < 2) return Value.FALSE;
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const suffix = values.getString(if (args[1].tag == .string) args[1].data.str_idx else 0);
    if (suffix.len > str.len) return Value.FALSE;
    return boolVal(eql(str[str.len - suffix.len ..], suffix));
}

fn strRepeat(args: []const Value) Value {
    if (args.len < 2) return if (args.len > 0) args[0] else Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const count: usize = safeIndex(args[1].toNumber());
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    for (0..@min(count, 2048 / (str.len + 1))) |_| {
        if (len + str.len > 2048) break;
        @memcpy(buf[len .. len + str.len], str);
        len += str.len;
    }
    return Value.string(values.internString(buf[0..len]));
}

fn strPadStart(args: []const Value) Value {
    // Simplified
    if (args.len > 0) return args[0];
    return Value.string(values.internString(""));
}

fn strPadEnd(args: []const Value) Value {
    if (args.len > 0) return args[0];
    return Value.string(values.internString(""));
}

var str_concat_buf: [1024 * 1024]u8 = undefined;
fn strConcat(args: []const Value) Value {
    if (args.len == 0 or args[0].tag == .undefined or args[0].tag == .null_val) {
        requestNativeThrow("String.concat requires a non-null receiver"); return Value.UNDEFINED;
    }
    // Convert before writing shared scratch storage: a user toString callback
    // can itself concatenate strings, and must not overwrite an outer prefix.
    var parts: [256]u32 = undefined;
    if (args.len > parts.len) { requestNativeThrow("String concatenation exceeds argument capacity"); return Value.UNDEFINED; }
    var total: usize = 0;
    for (args, 0..) |arg, i| {
        parts[i] = keyNameIdx(arg);
        if (native_throw) return Value.UNDEFINED;
        total += values.getStringLen(parts[i]);
        if (total > str_concat_buf.len) { requestNativeThrow("String concatenation exceeds fixed string capacity"); return Value.UNDEFINED; }
    }
    var used: usize = 0;
    for (parts[0..args.len]) |part| {
        const text = values.getString(part);
        @memcpy(str_concat_buf[used..][0..text.len], text);
        used += text.len;
    }
    return Value.string(values.internString(str_concat_buf[0..used]));
}

// ── Array implementations ──

fn arrPush(args: []const Value) Value {
    if (args.len < 2) return Value.number(0);
    if (args[0].tag != .object and args[0].tag != .array) return Value.number(0);
    const obj_idx: u32 = args[0].data.obj_idx;
    for (args[1..]) |a| objects.arrayPush(obj_idx, a);
    return Value.number(@floatFromInt(objects.arrayLength(obj_idx)));
}

fn arrPop(args: []const Value) Value {
    if (args.len == 0) return Value.UNDEFINED;
    if (args[0].tag != .object and args[0].tag != .array) return Value.UNDEFINED;
    const obj_idx: u32 = args[0].data.obj_idx;
    return objects.arrayPop(obj_idx);
}

fn arrConcat(args: []const Value) Value {
    // Array.prototype.concat(...items): new array = receiver elements followed by
    // each arg (arrays are spread one level; non-arrays appended as-is). Called
    // with NO args (`this.concat()`) it returns a shallow copy of the receiver —
    // BotGuard's register `.create` getter is `this.concat()`, so this must
    // return a real array (was undefined -> decode loop -> 30003 throws).
    const out = objects.createArray(0);
    if (args.len == 0) return Value.object(out);
    // args[0] = receiver.
    appendConcatArg(out, args[0]);
    var i: usize = 1;
    while (i < args.len) : (i += 1) appendConcatArg(out, args[i]);
    return Value.object(out);
}

fn appendConcatArg(out: u32, v: Value) void {
    if (v.tag == .array or (v.tag == .object and objects.objTypeOf(v.data.obj_idx) == .array)) {
        const src: u32 = v.data.obj_idx;
        const n = objects.arrayLength(src);
        var i: u32 = 0;
        while (i < n) : (i += 1) objects.arrayPush(out, objects.getArrayElement(src, i));
    } else {
        objects.arrayPush(out, v);
    }
}

fn isArrayVal(v: Value) bool {
    return v.tag == .array or (v.tag == .object and objects.objTypeOf(v.data.obj_idx) == .array);
}

/// Array.prototype.fill(value[, start[, end]]) — fills in place, returns the array.
fn arrFill(args: []const Value) Value {
    if (args.len == 0 or !isArrayVal(args[0])) return if (args.len > 0) args[0] else Value.UNDEFINED;
    const oi: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(oi);
    const fill_val = if (args.len >= 2) args[1] else Value.UNDEFINED;
    var start: u32 = 0;
    var end: u32 = len;
    if (args.len >= 3 and args[2].tag == .number) start = clampIndex(args[2].data.number, len);
    if (args.len >= 4 and args[3].tag == .number) end = clampIndex(args[3].data.number, len);
    var i: u32 = start;
    while (i < end) : (i += 1) objects.setArrayElement(oi, i, fill_val);
    return args[0];
}

/// Clamp a JS relative index (negative = from end) into [0, len].
fn clampIndex(n: f64, len: u32) u32 {
    if (n != n) return 0;
    if (n < 0) {
        const fe = @as(f64, @floatFromInt(len)) + n;
        return if (fe < 0) 0 else @intFromFloat(fe);
    }
    if (n > @as(f64, @floatFromInt(len))) return len;
    return @intFromFloat(n);
}

/// Array.prototype.flat([depth=1]) — flattens nested arrays into a new array.
fn arrFlat(args: []const Value) Value {
    if (args.len == 0 or !isArrayVal(args[0])) return Value.object(objects.createArray(0));
    var depth: i32 = 1;
    if (args.len >= 2 and args[1].tag == .number) {
        const d = args[1].data.number;
        depth = if (d != d or d < 0) 0 else if (d > 64) 64 else @intFromFloat(d);
    }
    const out = objects.createArray(0);
    flattenInto(out, @intCast(args[0].data.obj_idx), depth);
    return Value.object(out);
}

fn flattenInto(out: u32, src: u32, depth: i32) void {
    const n = objects.arrayLength(src);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const el = objects.getArrayElement(src, i);
        if (depth > 0 and isArrayVal(el)) {
            flattenInto(out, el.data.obj_idx, depth - 1);
        } else {
            objects.arrayPush(out, el);
        }
    }
}

/// Array.prototype.reverse() — reverses in place, returns the array.
fn arrReverse(args: []const Value) Value {
    if (args.len == 0 or !isArrayVal(args[0])) return if (args.len > 0) args[0] else Value.UNDEFINED;
    const oi: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(oi);
    if (len < 2) return args[0];
    var i: u32 = 0;
    var j: u32 = len - 1;
    while (i < j) {
        const a = objects.getArrayElement(oi, i);
        const b = objects.getArrayElement(oi, j);
        objects.setArrayElement(oi, i, b);
        objects.setArrayElement(oi, j, a);
        i += 1;
        j -= 1;
    }
    return args[0];
}

/// Array.prototype.sort() with the DEFAULT comparator (lexicographic on the
/// string form of each element) — in place, returns the array. A custom
/// comparator function would require VM re-entrancy; the default covers
/// BotGuard's numeric/string sorts adequately. Uses insertion sort (arrays are
/// small in the interpreter's usage).
fn arrSort(args: []const Value) Value {
    if (args.len == 0 or !isArrayVal(args[0])) return if (args.len > 0) args[0] else Value.UNDEFINED;
    const oi: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(oi);
    if (len < 2) return args[0];
    var i: u32 = 1;
    while (i < len) : (i += 1) {
        const cur = objects.getArrayElement(oi, i);
        var j: i64 = @as(i64, i) - 1;
        while (j >= 0) : (j -= 1) {
            const prev = objects.getArrayElement(oi, @intCast(j));
            if (defaultCompare(prev, cur) <= 0) break;
            objects.setArrayElement(oi, @intCast(j + 1), prev);
        }
        objects.setArrayElement(oi, @intCast(j + 1), cur);
    }
    return args[0];
}

/// Default JS sort comparator: compare the UTF-8 string forms lexicographically.
fn defaultCompare(a: Value, b: Value) i32 {
    var ba: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    const sa = valueToShortStr(a, &ba);
    const sb = valueToShortStr(b, &bb);
    var k: usize = 0;
    while (k < sa.len and k < sb.len) : (k += 1) {
        if (sa[k] < sb[k]) return -1;
        if (sa[k] > sb[k]) return 1;
    }
    if (sa.len < sb.len) return -1;
    if (sa.len > sb.len) return 1;
    return 0;
}

/// Minimal value -> string for sort comparison (numbers/strings/bool).
fn valueToShortStr(v: Value, buf: *[64]u8) []const u8 {
    switch (v.tag) {
        .string => {
            const s = values.getString(v.data.str_idx);
            const n = @min(s.len, 64);
            @memcpy(buf[0..n], s[0..n]);
            return buf[0..n];
        },
        .number => {
            const n = numToDecimal(v.data.number, buf);
            return buf[0..n];
        },
        .boolean => {
            const s: []const u8 = if (v.data.boolean != 0) "true" else "false";
            @memcpy(buf[0..s.len], s);
            return buf[0..s.len];
        },
        .undefined => return "undefined",
        .null_val => return "null",
        else => return "",
    }
}

/// Object.values(o) — array of own enumerable property values.
fn objValues(args: []const Value) Value {
    const out = objects.createArray(0);
    if (args.len < 2) return Value.object(out);
    const src = args[1];
    if (src.tag != .object and src.tag != .array) return Value.object(out);
    const oi: u32 = src.data.obj_idx;
    const pc = objects.ownPropCount(oi);
    var i: u16 = 0;
    while (i < pc) : (i += 1) {
        const name = objects.ownPropNameAt(oi, i);
        objects.arrayPush(out, objects.getProperty(oi, name));
    }
    return Value.object(out);
}

/// Object.entries(o) — array of [key, value] pairs.
fn objEntries(args: []const Value) Value {
    const out = objects.createArray(0);
    if (args.len < 2) return Value.object(out);
    const src = args[1];
    if (src.tag != .object and src.tag != .array) return Value.object(out);
    const oi: u32 = src.data.obj_idx;
    const pc = objects.ownPropCount(oi);
    var i: u16 = 0;
    while (i < pc) : (i += 1) {
        const name = objects.ownPropNameAt(oi, i);
        const pair = objects.createArray(0);
        objects.arrayPush(pair, Value.string(name));
        objects.arrayPush(pair, objects.getProperty(oi, name));
        objects.arrayPush(out, Value.object(pair));
    }
    return Value.object(out);
}

/// Object.assign(target, ...sources) — copies own enumerable props into target.
fn objAssign(args: []const Value) Value {
    if (args.len < 2) return if (args.len > 0) args[1] else Value.UNDEFINED;
    const target = args[1];
    if (target.tag != .object and target.tag != .array) return target;
    const ti: u32 = target.data.obj_idx;
    var s: usize = 2;
    while (s < args.len) : (s += 1) {
        const src = args[s];
        if (src.tag != .object and src.tag != .array) continue;
        const si: u32 = src.data.obj_idx;
        const pc = objects.ownPropCount(si);
        var i: u16 = 0;
        while (i < pc) : (i += 1) {
            const name = objects.ownPropNameAt(si, i);
            objects.setProperty(ti, name, objects.getProperty(si, name));
        }
    }
    return target;
}

/// Number.prototype.toString([radix]) — args[0]=receiver number, args[1]=radix.
fn numberToString(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString("0"));
    const n = args[0].toNumber();
    var radix: u32 = 10;
    if (args.len >= 2 and args[1].tag == .number) {
        const r = args[1].data.number;
        if (r >= 2 and r <= 36) radix = @intFromFloat(r);
    }
    var buf: [72]u8 = undefined;
    const len = numToRadixStr(n, radix, &buf);
    return Value.string(values.internString(buf[0..len]));
}

/// Format a number in the given radix (2..36). Integer part only for non-10
/// radices (JS supports fractions but BotGuard uses integer radix conversion,
/// e.g. (n).toString(16)/(36)). Base 10 uses the full decimal formatter.
fn numToRadixStr(n: f64, radix: u32, buf: *[72]u8) usize {
    if (n != n) { const s = "NaN"; @memcpy(buf[0..s.len], s); return s.len; }
    if (radix == 10) return numToDecimal(n, buf);
    // Integer conversion for radix != 10.
    var neg = false;
    var v: f64 = n;
    if (v < 0) { neg = true; v = -v; }
    var iv: u64 = @intFromFloat(@floor(v));
    var tmp: [72]u8 = undefined;
    var t: usize = 0;
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    if (iv == 0) { tmp[0] = '0'; t = 1; } else {
        while (iv > 0 and t < tmp.len) : (t += 1) {
            tmp[t] = digits[@intCast(iv % radix)];
            iv /= radix;
        }
    }
    var o: usize = 0;
    if (neg) { buf[0] = '-'; o = 1; }
    var k: usize = 0;
    while (k < t) : (k += 1) buf[o + k] = tmp[t - 1 - k];
    return o + t;
}

fn arrShift(args: []const Value) Value {
    if (args.len == 0) return Value.UNDEFINED;
    if (args[0].tag != .object and args[0].tag != .array) return Value.UNDEFINED;
    return objects.arrayShift(@intCast(args[0].data.obj_idx));
}

fn arrUnshift(args: []const Value) Value {
    // args[0]=receiver, args[1..]=values to prepend (BotGuard uses single-arg).
    if (args.len == 0) return Value.number(0);
    if (args[0].tag != .object and args[0].tag != .array) return Value.number(0);
    const oi: u32 = args[0].data.obj_idx;
    // Insert args in order so the last unshift leaves them front-to-back.
    var i: usize = args.len;
    while (i > 1) : (i -= 1) {
        _ = objects.arrayUnshift(oi, args[i - 1]);
    }
    return Value.number(@floatFromInt(objects.arrayLength(oi)));
}

fn arrSplice(args: []const Value) Value {
    // args[0]=receiver, args[1]=start, args[2]=deleteCount (removal only).
    if (args.len == 0) return Value.UNDEFINED;
    if (args[0].tag != .object and args[0].tag != .array) return Value.UNDEFINED;
    const oi: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(oi);
    // Resolve start (supports negative offset from end).
    var start: u32 = 0;
    if (args.len >= 2 and args[1].tag == .number) {
        const s = args[1].data.number;
        if (s < 0) {
            const from_end = @as(f64, @floatFromInt(len)) + s;
            start = if (from_end < 0) 0 else @intFromFloat(from_end);
        } else if (s > @as(f64, @floatFromInt(len))) {
            start = len;
        } else start = @intFromFloat(s);
    }
    // Resolve deleteCount (default: to end).
    var del: u32 = if (len > start) len - start else 0;
    if (args.len >= 3 and args[2].tag == .number) {
        const d = args[2].data.number;
        del = if (d < 0) 0 else @intFromFloat(d);
    }
    // Collect removed elements into a new array (JS returns them).
    const removed = objects.createArray(0);
    var k: u32 = 0;
    while (k < del and start + k < len) : (k += 1) {
        objects.arrayPush(removed, objects.getArrayElement(oi, start + k));
    }
    _ = objects.arraySpliceRemove(oi, start, del);
    // Insert any items (args[3..]) at `start`. `H.splice(0,0,instr)` relies on
    // this to prepend to the interpreter's instruction queue.
    if (args.len > 3) {
        const insert_count: u32 = @intCast(args.len - 3);
        objects.arrayMakeGap(oi, start, insert_count);
        var j: u32 = 0;
        while (j < insert_count) : (j += 1) {
            objects.setArrayElement(oi, start + j, args[3 + j]);
        }
    }
    return Value.object(removed);
}

// Scratch buffer for Array.prototype.join. BotGuard assembles its VM payload
// via [...].join('\n'), which can be tens of KB.
var join_buf: [512 * 1024]u8 = undefined;

fn arrJoin(args: []const Value) Value {
    // args[0] = receiver array; args[1] = optional separator (default ",").
    if (args.len == 0) return Value.string(values.internString(""));
    if (args[0].tag != .object and args[0].tag != .array) return Value.string(values.internString(""));
    const arr_idx: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(arr_idx);

    var sep: []const u8 = ",";
    if (args.len >= 2 and args[1].tag == .string) {
        sep = values.getString(args[1].data.str_idx);
    }

    var o: usize = 0;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (i > 0) {
            if (o + sep.len > join_buf.len) break;
            @memcpy(join_buf[o .. o + sep.len], sep);
            o += sep.len;
        }
        const el = objects.getArrayElement(arr_idx, i);
        o = appendValueText(el, o);
    }
    return Value.string(values.internString(join_buf[0..o]));
}

/// Append a value's string form to join_buf at offset o; returns new offset.
/// null/undefined join as empty (per JS Array.prototype.join semantics).
fn appendValueText(v: Value, o_in: usize) usize {
    var o = o_in;
    switch (v.tag) {
        .string => {
            const s = values.getString(v.data.str_idx);
            if (o + s.len <= join_buf.len) { @memcpy(join_buf[o .. o + s.len], s); o += s.len; }
        },
        .number => {
            var nb: [32]u8 = undefined;
            const nl = numberToText(v.data.number, &nb);
            if (o + nl <= join_buf.len) { @memcpy(join_buf[o .. o + nl], nb[0..nl]); o += nl; }
        },
        .boolean => {
            const s = if (v.data.boolean != 0) "true" else "false";
            if (o + s.len <= join_buf.len) { @memcpy(join_buf[o .. o + s.len], s); o += s.len; }
        },
        .undefined, .null_val => {}, // empty
        else => {},
    }
    return o;
}

/// Minimal integer/float formatting for join (BotGuard values are integers).
fn numberToText(n: f64, buf: *[32]u8) usize {
    if (n != n) { @memcpy(buf[0..3], "NaN"); return 3; }
    if (n == 0) { buf[0] = '0'; return 1; }
    var len: usize = 0;
    var val = n;
    if (val < 0) { buf[0] = '-'; len = 1; val = -val; }
    if (val >= 1.8e19) val = 0; // beyond u64 range — degrade gracefully
    const int_part: u64 = @intFromFloat(@floor(val));
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var tmp = int_part;
    if (tmp == 0) { digits[0] = '0'; d = 1; } else {
        while (tmp > 0) : (d += 1) { digits[d] = @intCast((tmp % 10) + '0'); tmp /= 10; }
    }
    var k: usize = 0;
    while (k < d) : (k += 1) { buf[len + k] = digits[d - 1 - k]; }
    len += d;
    return len;
}

fn arrIncludes(args: []const Value) Value {
    if (args.len < 2) return Value.FALSE;
    if (args[0].tag != .object and args[0].tag != .array) return Value.FALSE;
    const obj_idx: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(obj_idx);
    for (0..len) |i| {
        const elem = objects.getArrayElement(obj_idx, @intCast(i));
        if (elem.tag == args[1].tag and elem.data.number == args[1].data.number) return Value.TRUE;
    }
    return Value.FALSE;
}

fn arrIndexOf(args: []const Value) Value {
    if (args.len < 2) return Value.number(-1);
    if (args[0].tag != .object and args[0].tag != .array) return Value.number(-1);
    const obj_idx: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(obj_idx);
    for (0..len) |i| {
        const elem = objects.getArrayElement(obj_idx, @intCast(i));
        if (elem.tag == args[1].tag and elem.data.number == args[1].data.number) return Value.number(@floatFromInt(i));
    }
    return Value.number(-1);
}

pub var dbg_slice_calls: u32 = 0;
pub var dbg_slice_maxlen: u32 = 0;
pub var dbg_slice_last_srclen: u32 = 0;
pub var dbg_slice_last_dstlen: u32 = 0;
fn arrSlice(args: []const Value) Value {
    if (args.len >= 1 and (args[0].tag == .array or args[0].tag == .object)) {
        const sl = objects.arrayLength(@intCast(args[0].data.obj_idx));
        dbg_slice_calls += 1;
        dbg_slice_last_srclen = sl;
        if (sl > dbg_slice_maxlen) dbg_slice_maxlen = sl;
    }
    if (args.len == 0) return Value.object(objects.createArray(0));
    if (args[0].tag != .object and args[0].tag != .array) return Value.object(objects.createArray(0));
    const obj_idx: u32 = args[0].data.obj_idx;
    const len: i64 = @intCast(objects.arrayLength(obj_idx));
    var start: i64 = if (args.len > 1) toI64(args[1].toNumber()) else 0;
    var end: i64 = if (args.len > 2) toI64(args[2].toNumber()) else len;
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    if (start >= end) return Value.object(objects.createArray(0));
    const count: u32 = @intCast(@min(end - start, len));
    const new_arr = objects.createArray(count);
    for (0..count) |i| {
        const elem = objects.getArrayElement(obj_idx, @intCast(@as(i64, @intCast(i)) + start));
        objects.setArrayElement(new_arr, @intCast(i), elem);
    }
    dbg_slice_last_dstlen = count;
    return Value.object(new_arr);
}

fn arrFrom(args: []const Value) Value {
    // Simplified: if arg is array, return copy; else create [arg]
    if (args.len > 0 and (args[0].tag == .object or args[0].tag == .array)) return args[0];
    const arr = objects.createArray(if (args.len > 0) 1 else 0);
    if (args.len > 0) objects.setArrayElement(arr, 0, args[0]);
    return Value.object(arr);
}

/// Array(...) constructor. Array(n) -> array of length n; Array(a,b,...) -> [a,b,...].
fn arrayCtor(args: []const Value) Value {
    if (args.len == 1 and args[0].tag == .number) {
        const n = safeLen(args[0].toNumber());
        const arr = objects.createArray(n);
        return Value.object(arr);
    }
    const arr = objects.createArray(@intCast(args.len));
    for (args, 0..) |a, i| objects.setArrayElement(arr, @intCast(i), a);
    return Value.object(arr);
}

/// Safely convert a float to an array length, clamping NaN/negative/huge values.
fn safeLen(n: f64) u32 {
    if (n != n) return 0; // NaN
    if (n <= 0) return 0;
    if (n >= 100000.0) return 100000; // cap to keep the array pool bounded
    return @intFromFloat(n);
}

fn objKeys(args: []const Value) Value {
    // Object.keys(o): array of own enumerable string keys. args[0]=Object recv,
    // args[1]=the object. For arrays, keys are the numeric indices as strings.
    const out = objects.createArray(0);
    if (args.len < 2) return Value.object(out);
    const src = args[1];
    if (src.tag != .object and src.tag != .array and src.tag != .function) return Value.object(out);
    const oi: u32 = src.data.obj_idx;
    var keys: [objects.MAX_ENUM_KEYS]u32 = undefined;
    const n = objects.enumerateOwnKeys(oi, &keys, true);
    for (keys[0..n]) |key| objects.arrayPush(out, Value.string(key));
    return Value.object(out);
}

// ── Global functions ──

fn nParseInt(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    if (args[0].tag == .number) return args[0];
    if (args[0].tag != .string) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const str = values.getString(args[0].data.str_idx);
    var val: f64 = 0;
    var sign: f64 = 1;
    var i: usize = 0;
    // Skip whitespace
    while (i < str.len and isWhitespace(str[i])) i += 1;
    if (i < str.len and str[i] == '-') { sign = -1; i += 1; }
    if (i < str.len and str[i] == '+') i += 1;
    var found = false;
    while (i < str.len and str[i] >= '0' and str[i] <= '9') : (i += 1) {
        val = val * 10 + @as(f64, @floatFromInt(str[i] - '0'));
        found = true;
    }
    if (!found) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    return Value.number(sign * val);
}

fn nParseFloat(args: []const Value) Value {
    return nParseInt(args); // simplified
}

fn nIsFinite(args: []const Value) Value {
    if (args.len == 0) return Value.FALSE;
    const n = args[0].toNumber();
    return boolVal(n == n and n != @as(f64, @bitCast(@as(u64, 0x7FF0000000000000))) and n != -@as(f64, @bitCast(@as(u64, 0x7FF0000000000000))));
}

// atob output buffer: the BotGuard program base64 (~9.8 KB) decodes to ~7.3 KB.
// A 2048-byte buffer truncated it, so the VM's program bit-length (H = YK.len<<3)
// was wrong (16368 instead of ~58704), making the interpreter break early on the
// first computed jump past 16368. Size generously for the full program.
var atob_buf: [65536]u8 = undefined;
fn nAtob(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const len = base64Decode(str, atob_buf[0..]);
    return Value.string(values.internString(atob_buf[0..len]));
}

var btoa_buf: [24576]u8 = undefined;
fn nBtoa(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const len = base64Encode(str, &btoa_buf);
    return Value.string(values.internString(btoa_buf[0..len]));
}

fn dateNow() Value {
    // Return a plausible timestamp (BotGuard uses for timing checks)
    // We return a fixed value to avoid detection
    return Value.number(1703980800000); // 2023-12-31T00:00:00Z
}

// performance.now(): a SMALL, monotonically-increasing millisecond value
// relative to "page load" (starts near 0). BotGuard's interpreter clock is
// `this.wM + performance.now()` and it debits a per-instruction time budget
// (register fields fi/Ci). If this returned the Date epoch (~1.7e12) the budget
// arithmetic exploded and the timing-gate `pM` took the wrong branch (skipping
// opcode-handler installs), which broke live challenges. A small advancing
// value keeps the budget in the same regime V8 sees (verified: V8 with
// performance.now()=>~0 still mints a valid response). We advance by a tiny
// fixed step per call so elapsed-time deltas are ~0 but strictly monotonic.
var perf_now_ms: f64 = 0;
fn perfNow() Value {
    const v = perf_now_ms;
    perf_now_ms += 0.005; // 5µs per call — monotonic, negligible elapsed
    return Value.number(v);
}
pub fn resetPerfNow() void {
    perf_now_ms = 0;
}

fn textEncode(args: []const Value) Value {
    // TextEncoder.encode(str) → Uint8Array
    if (args.len == 0) return Value.object(objects.createArray(0));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const arr = objects.createArray(@intCast(str.len));
    for (0..str.len) |i| {
        objects.setArrayElement(arr, @intCast(i), Value.number(@floatFromInt(str[i])));
    }
    return Value.object(arr);
}

fn textDecode(args: []const Value) Value {
    // TextDecoder.decode(arr) → string
    if (args.len == 0) return Value.string(values.internString(""));
    if (args[0].tag != .object and args[0].tag != .array) return Value.string(values.internString(""));
    const obj_idx: u32 = args[0].data.obj_idx;
    const len = @min(objects.arrayLength(obj_idx), 2048);
    var buf: [2048]u8 = undefined;
    for (0..len) |i| {
        const elem = objects.getArrayElement(obj_idx, @intCast(i));
        buf[i] = @intCast(toU16(elem.toNumber()) & 0xFF);
    }
    return Value.string(values.internString(buf[0..len]));
}

fn cryptoRandom(args: []const Value) Value {
    // crypto.getRandomValues(arr)
    if (args.len == 0) return Value.UNDEFINED;
    if (args[0].tag != .object and args[0].tag != .array) return args[0];
    const obj_idx: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(obj_idx);
    for (0..len) |i| {
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 7;
        rng_state ^= rng_state << 17;
        objects.setArrayElement(obj_idx, @intCast(i), Value.number(@floatFromInt(rng_state & 0xFF)));
    }
    return args[0];
}

fn createTypedArrayN(args: []const Value, elem_size: u8) Value {
    var len: u32 = 0;
    if (args.len > 0 and args[0].tag == .number) {
        len = safeLen(args[0].toNumber());
    } else if (args.len > 0 and (args[0].tag == .object or args[0].tag == .array)) {
        // new Uint8Array(existingArray) — copy its elements.
        const src: u32 = args[0].data.obj_idx;
        const slen = @min(objects.arrayLength(src), 100000);
        const buf2 = objects.createArrayBuffer(slen * elem_size);
        const ta2 = objects.createTypedArray(buf2, 0, slen, elem_size);
        var i: u32 = 0;
        while (i < slen) : (i += 1) objects.setArrayElement(ta2, i, objects.getArrayElement(src, i));
        return Value.object(ta2);
    }
    const buf = objects.createArrayBuffer(len * elem_size);
    const ta = objects.createTypedArray(buf, 0, len, elem_size);
    return Value.object(ta);
}

fn createArrayBufferN(args: []const Value) Value {
    var len: u32 = 0;
    if (args.len > 0 and args[0].tag == .number) {
        len = safeLen(args[0].toNumber());
    }
    return Value.object(objects.createArrayBuffer(len));
}

fn createDataViewN(args: []const Value) Value {
    if (args.len > 0 and (args[0].tag == .object or args[0].tag == .array)) {
        return args[0]; // simplified: return the buffer object
    }
    return Value.object(objects.createObject());
}

fn jsonParse(args: []const Value) Value {
    // Minimal JSON parser — handles BotGuard's simple JSON strings
    if (args.len == 0) return Value.UNDEFINED;
    if (args[0].tag != .string) return Value.UNDEFINED;
    const str = values.getString(args[0].data.str_idx);
    if (str.len == 0) return Value.UNDEFINED;
    // Very simplified: just return the string as-is for now
    // Full JSON parse needed for production
    return args[0];
}

fn jsonStringify(args: []const Value) Value {
    if (args.len == 0) return Value.UNDEFINED;
    // Simplified: return type-appropriate string
    return switch (args[0].tag) {
        .string => args[0],
        .number => blk: {
            var buf: [32]u8 = undefined;
            const n = args[0].data.number;
            if (n != n) break :blk Value.string(values.internString("NaN"));
            const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
            if (n == inf) break :blk Value.string(values.internString("Infinity"));
            if (n == -inf) break :blk Value.string(values.internString("-Infinity"));
            // Integer fast path via safe clamp (toI64 handles huge/NaN); the
            // fractional part is dropped here — BotGuard's String(number) usage
            // is on integer char/byte values, so this is sufficient and safe.
            const i: i64 = toI64(@trunc(n));
            var d: usize = 0;
            var tmp = if (i < 0) @as(u64, @intCast(-i)) else @as(u64, @intCast(i));
            var digits: [20]u8 = undefined;
            if (tmp == 0) { digits[0] = '0'; d = 1; } else {
                while (tmp > 0) : (d += 1) { digits[d] = @intCast((tmp % 10) + '0'); tmp /= 10; }
            }
            var len: usize = 0;
            if (i < 0) { buf[0] = '-'; len = 1; }
            var j: usize = 0;
            while (j < d) : (j += 1) { buf[len + j] = digits[d - 1 - j]; }
            len += d;
            break :blk Value.string(values.internString(buf[0..len]));
        },
        .boolean => if (args[0].data.boolean != 0) Value.string(values.internString("true")) else Value.string(values.internString("false")),
        .null_val => Value.string(values.internString("null")),
        else => Value.string(values.internString("null")),
    };
}

fn isInteger(v: Value) bool {
    if (v.tag != .number) return false;
    const n = v.data.number;
    if (n != n) return false; // NaN
    const inf = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    if (n == inf or n == -inf) return false;
    // An integer-valued double equals its own truncation. @trunc never panics.
    return @trunc(n) == n;
}

// ── Base64 ──

const B64_TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Encode(data: []const u8, out: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i + 2 < data.len) : (i += 3) {
        if (o + 4 > 4096) break;
        const b0 = data[i];
        const b1 = data[i + 1];
        const b2 = data[i + 2];
        out[o] = B64_TABLE[b0 >> 2]; o += 1;
        out[o] = B64_TABLE[((b0 & 3) << 4) | (b1 >> 4)]; o += 1;
        out[o] = B64_TABLE[((b1 & 0xF) << 2) | (b2 >> 6)]; o += 1;
        out[o] = B64_TABLE[b2 & 0x3F]; o += 1;
    }
    if (i < data.len and o + 4 <= 4096) {
        const b0 = data[i];
        out[o] = B64_TABLE[b0 >> 2]; o += 1;
        if (i + 1 < data.len) {
            const b1 = data[i + 1];
            out[o] = B64_TABLE[((b0 & 3) << 4) | (b1 >> 4)]; o += 1;
            out[o] = B64_TABLE[(b1 & 0xF) << 2]; o += 1;
        } else {
            out[o] = B64_TABLE[(b0 & 3) << 4]; o += 1;
            out[o] = '='; o += 1;
        }
        out[o] = '='; o += 1;
    }
    return o;
}

fn base64Decode(data: []const u8, out: []u8) usize {
    const cap = out.len;
    var o: usize = 0;
    var i: usize = 0;
    while (i + 3 < data.len and o + 3 <= cap) : (i += 4) {
        const a = b64Val(data[i]);
        const b = b64Val(data[i + 1]);
        const c = b64Val(data[i + 2]);
        const d = b64Val(data[i + 3]);
        out[o] = (a << 2) | (b >> 4); o += 1;
        if (data[i + 2] != '=') { out[o] = (b << 4) | (c >> 2); o += 1; }
        if (data[i + 3] != '=') { out[o] = (c << 6) | d; o += 1; }
    }
    return o;
}

fn b64Val(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a' + 26;
    if (c >= '0' and c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return 0;
}

// ── Helpers ──

fn installNativeMethod(obj: u32, name: []const u8, func_id: u16) void {
    const func_obj = objects.createFunction(func_id);
    objects.setProperty(obj, values.internString(name), Value.function(func_obj));
    objects.setEnumerable(obj, values.internString(name), false);
}

fn installNativeGlobal(global: u32, name: []const u8, func_id: u16) void {
    const func_obj = objects.createFunction(func_id);
    objects.setProperty(global, values.internString(name), Value.function(func_obj));
}

fn boolVal(b: bool) Value {
    return if (b) Value.TRUE else Value.FALSE;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}
