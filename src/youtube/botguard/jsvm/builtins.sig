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
const std = @import("std");
const objects = @import("objects.sig");
const compiler = @import("compiler.sig");
const regexp = @import("regexp.sig");
const browser_metadata = @import("browser_metadata.sig");
const events = @import("events.sig");
const Value = values.Value;
// The VM supplies synchronous JavaScript callback execution without a reverse
// import from native builtins into the interpreter.
pub var invoke_callback: ?*const fn (Value, Value, []const Value) Value = null;
pub var callback_aborted: ?*const fn () bool = null;
fn callbackAborted() bool { return if (callback_aborted) |aborted| aborted() else false; }

// ── Debug print (console.log) ──
extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
const FileTime = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetSystemTimeAsFileTime(*FileTime) void;
const SystemTime = extern struct { year: u16, month: u16, weekday: u16, day: u16, hour: u16, minute: u16, second: u16, millis: u16 };
extern "kernel32" fn FileTimeToSystemTime(*const FileTime, *SystemTime) c_int;
extern "kernel32" fn SystemTimeToTzSpecificLocalTime(?*const anyopaque, *const SystemTime, *SystemTime) c_int;
extern "bcrypt" fn BCryptGenRandom(?*anyopaque, [*]u8, u32, u32) callconv(.c) i32;
extern "kernel32" fn QueryPerformanceCounter(*i64) c_int;
extern "kernel32" fn QueryPerformanceFrequency(*i64) c_int;
extern "kernel32" fn GetTickCount64() u64;
extern "kernel32" fn Sleep(u32) void;
const TimeZoneInformation = extern struct { bias: i32, standard_name: [32]u16, standard_date: SystemTime, standard_bias: i32, daylight_name: [32]u16, daylight_date: SystemTime, daylight_bias: i32 };
extern "kernel32" fn GetTimeZoneInformation(*TimeZoneInformation) u32;
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
pub const N_MATH_ATAN2: u16 = NATIVE_BASE + 15;
pub const N_OBJ_IS_FROZEN: u16 = NATIVE_BASE + 300;

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
pub const N_DATE_VALUE_OF: u16 = NATIVE_BASE + 124;
pub const N_DATE_HOURS: u16 = NATIVE_BASE + 125;
pub const N_DATE_MINUTES: u16 = NATIVE_BASE + 126;
pub const N_DATE_ZONE_OFFSET: u16 = NATIVE_BASE + 127;
pub const N_OBJ_OWN_NAMES: u16 = NATIVE_BASE + 128;
var date_proto: u32 = objects.NULL_OBJ;

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
pub const N_DOM_REPLACE_CHILD: u16 = NATIVE_BASE + 146;
pub const N_DOM_LOOKUP_NAMESPACE: u16 = NATIVE_BASE + 147;
pub const N_DOM_FALSE: u16 = NATIVE_BASE + 148;
pub const N_DOM_IMAGE: u16 = NATIVE_BASE + 149;
pub const N_DOM_EMPTY_STRING: u16 = NATIVE_BASE + 151;
pub const N_DOM_MATCH_MEDIA: u16 = NATIVE_BASE + 152;
pub const N_DOM_ORIENTATION_EVENT: u16 = NATIVE_BASE + 153;
pub const N_ARR_TOSTRING: u16 = NATIVE_BASE + 155;
pub const N_DOM_RECT: u16 = NATIVE_BASE + 156;
pub var dom_element_proto: u32 = objects.NULL_OBJ;
pub var dom_style_proto: u32 = objects.NULL_OBJ;
pub const N_TT_CREATE_POLICY: u16 = NATIVE_BASE + 243; // trustedTypes.createPolicy -> passthrough policy
pub const N_TT_IDENTITY: u16 = NATIVE_BASE + 244; // policy.createScript/createHTML(s) -> s (passthrough)
pub const N_FN_TOSTRING: u16 = NATIVE_BASE + 245; // Function.prototype.toString -> source text
pub const N_REGEXP_CTOR: u16 = NATIVE_BASE + 246;
pub const N_REGEXP_EXEC: u16 = NATIVE_BASE + 247;
pub const N_REGEXP_TEST: u16 = NATIVE_BASE + 248;
pub const N_REGEXP_TOSTRING: u16 = NATIVE_BASE + 249;
pub const N_QUEUE_MICROTASK: u16 = NATIVE_BASE + 250;
pub const N_DATE_TOSTRING: u16 = NATIVE_BASE + 251;
pub const N_NUMBER_VALUE_OF: u16 = NATIVE_BASE + 252;
pub const N_BOOLEAN_VALUE_OF: u16 = NATIVE_BASE + 253;
pub const N_BOOLEAN_TOSTRING: u16 = NATIVE_BASE + 254;
pub const N_BOOLEAN_CTOR: u16 = NATIVE_BASE + 255;
pub const N_FUNCTION_PROTO: u16 = NATIVE_BASE + 256;
pub const N_EVENT_ADD: u16 = NATIVE_BASE + 257;
pub const N_EVENT_REMOVE: u16 = NATIVE_BASE + 258;
pub const N_EVENT_DISPATCH: u16 = NATIVE_BASE + 259;
pub const N_DOM_CLICK: u16 = NATIVE_BASE + 260;
pub const N_EVENT_CTOR: u16 = NATIVE_BASE + 261;
pub const N_EVENT_PREVENT: u16 = NATIVE_BASE + 262;
pub const N_EVENT_STOP_IMMEDIATE: u16 = NATIVE_BASE + 263;
pub const N_MEDIA_CAN_PLAY: u16 = NATIVE_BASE + 264;
pub const N_IFRAME_WINDOW: u16 = NATIVE_BASE + 265;
pub const N_IFRAME_DOCUMENT: u16 = NATIVE_BASE + 266;
pub const N_IFRAME_SRCDOC: u16 = NATIVE_BASE + 267;
pub const N_IFRAME_SET_SRCDOC: u16 = NATIVE_BASE + 268;
pub const N_DOC_HAS_FOCUS: u16 = NATIVE_BASE + 269;
pub const N_DOM_APPEND: u16 = NATIVE_BASE + 270;
pub const N_DOM_REMOVE: u16 = NATIVE_BASE + 271;
pub const N_DOM_FRAME_LOAD: u16 = NATIVE_BASE + 272;
pub const N_DOM_EMPTY_OBJECT: u16 = NATIVE_BASE + 273;
pub const N_NAV_WEBDRIVER: u16 = NATIVE_BASE + 274;
pub const N_DOM_INSERT_BEFORE: u16 = NATIVE_BASE + 275;
pub const N_DOM_CREATE_TEXT: u16 = NATIVE_BASE + 276;
pub const N_DOM_CREATE_COMMENT: u16 = NATIVE_BASE + 277;
pub var dbg_iframe_reads: u32 = 0;
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
pub var dom_document_obj: u32 = objects.NULL_OBJ;
pub var dom_window_template: u32 = objects.NULL_OBJ;
pub var dbg_bg_telemetry_calls: u32 = 0;
pub var dbg_bg_logger_calls: u32 = 0;
pub var bg_snapshot_response: Value = Value.UNDEFINED; // captured botguardResponse string
pub var bg_snapshot_result_called: bool = false;

// Caller-bounded event queue. Slots are reclaimed before one-shot callbacks
// run, so recursive scheduling cannot exhaust an append-only queue. Timers
// share cancellable IDs; microtasks have priority over ready timers.
const MAX_TASKS: usize = 256;
pub const Task = struct {
    callback: Value = Value.UNDEFINED,
    args: [8]Value = [_]Value{Value.UNDEFINED} ** 8,
    argc: u8 = 0,
    id: u32 = 0,
    due: u64 = 0,
    interval: u32 = 0,
    microtask: bool = false,
    active: bool = false,
};
var tasks: [MAX_TASKS]Task = undefined;
var task_next_id: u32 = 1;
pub fn taskQueueReset() void {
    events.reset();
    for (&tasks) |*task| task.* = .{};
    task_next_id = 1;
}
pub fn taskClock() u64 { return GetTickCount64(); }

fn enqueueTask(args: []const Value, repeat: bool, microtask: bool) Value {
    if (args.len == 0 or args[0].tag != .function) {
        requestNativeThrow("Task callback must be a function");
        return Value.UNDEFINED;
    }
    const extra: usize = if (!microtask and args.len > 2) args.len - 2 else 0;
    if (extra > 8) { requestRangeError("Task argument capacity exceeded"); return Value.UNDEFINED; }
    var free: ?usize = null;
    for (tasks, 0..) |task, i| if (!task.active) { free = i; break; };
    const slot = free orelse { requestRangeError("Task queue capacity exceeded"); return Value.UNDEFINED; };
    const delay = if (!microtask and args.len > 1) args[1].toNumber() else 0;
    const millis: u32 = if (delay > 0 and delay <= 2147483647) @intFromFloat(@trunc(delay)) else 0;
    var id = task_next_id;
    // IDs remain unique among outstanding timers even after integer wrap.
    while (true) {
        var occupied = false;
        for (tasks) |task| if (task.active and task.id == id) { occupied = true; break; };
        if (!occupied) break;
        id +%= 1;
        if (id == 0) id = 1;
    }
    task_next_id = id +% 1;
    if (task_next_id == 0) task_next_id = 1;
    tasks[slot] = .{ .callback = args[0], .id = id, .argc = @intCast(extra), .due = taskClock() + millis, .interval = if (repeat) @max(millis, 1) else 0, .microtask = microtask, .active = true };
    for (0..extra) |i| tasks[slot].args[i] = args[i + 2];
    return if (microtask) Value.UNDEFINED else Value.number(@floatFromInt(id));
}

fn cancelTask(args: []const Value) Value {
    if (args.len == 0) return Value.UNDEFINED;
    const number = args[0].toNumber();
    if (number < 1 or number > 4294967295 or number != number) return Value.UNDEFINED;
    const id: u32 = @intFromFloat(@trunc(number));
    for (&tasks) |*task| if (task.active and task.id == id) { task.active = false; break; };
    return Value.UNDEFINED;
}

/// Take one event, waiting only within the caller's absolute deadline. Copy
/// arguments before invoking JS: its callback may reuse this queue slot.
pub fn takeTask(deadline: u64) ?Task {
    var chosen: ?usize = null;
    for (tasks, 0..) |task, i| {
        if (!task.active) continue;
        if (chosen) |old| {
            const previous = tasks[old];
            if ((task.microtask and !previous.microtask) or (task.microtask == previous.microtask and (task.due < previous.due or (task.due == previous.due and task.id < previous.id)))) chosen = i;
        } else chosen = i;
    }
    const index = chosen orelse return null;
    const task = tasks[index];
    if (!task.microtask) {
        const now = taskClock();
        if (task.due > deadline) return null;
        if (task.due > now) Sleep(@intCast(@min(task.due - now, 4294967295)));
    }
    if (task.interval == 0) tasks[index].active = false else tasks[index].due = taskClock() + task.interval;
    return task;
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
    if (func_id == N_EVENT_CTOR or func_id == N_DOM_FRAME_LOAD) return true;
    if (func_id == N_OBJ_FREEZE or func_id == N_OBJ_IS_FROZEN) return true;
    if (func_id >= N_MATH_FLOOR and func_id <= N_MATH_ATAN2) return true;
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
        func_id == N_CLEAR_TIMEOUT or func_id == N_QUEUE_MICROTASK or func_id == N_CONSOLE_LOG or
        func_id == N_BG_VM_SETUP or func_id == N_BG_SNAPSHOT_RESULT or
        func_id == N_BG_TELEMETRY or func_id == N_BG_LOGGER) return true;
    return func_id == N_STRING_CTOR or func_id == N_NUMBER_CTOR or func_id == N_BOOLEAN_CTOR or func_id == N_REGEXP_CTOR or
        func_id == N_OBJECT_CTOR or func_id == N_PARSE_INT or func_id == N_PARSE_FLOAT or
        func_id == N_IS_NAN or func_id == N_IS_FINITE or
        func_id == N_ENCODE_URI or func_id == N_DECODE_URI or
        func_id == N_ATOB or func_id == N_BTOA;
}
/// Native methods are nonconstructible and have no automatic prototype.
/// Host constructors install their own prototypes when their interface is built.
pub fn nativeHasPrototype(id: u16) bool {
    return switch (id) {
        N_OBJECT_CTOR, N_ARRAY_CTOR, N_STRING_CTOR, N_NUMBER_CTOR, N_BOOLEAN_CTOR, N_EVENT_CTOR,
        N_DATE_CTOR, N_REGEXP_CTOR, N_ERROR_CTOR, N_REFERROR_CTOR, N_TYPEERROR_CTOR,
        N_UINT8_ARRAY, N_UINT16_ARRAY, N_UINT32_ARRAY, N_INT8_ARRAY,
        N_ARRAY_BUFFER, N_DATA_VIEW, N_TEXT_ENCODE, N_TEXT_DECODE, N_FUNCTION, N_SYMBOL => true,
        else => false,
    };
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
    resetPerfNow();
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
    installNativeMethod(math_obj, "atan2", N_MATH_ATAN2);
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
    installNativeMethod(obj_constructor, "getOwnPropertyNames", N_OBJ_OWN_NAMES);
    installNativeMethod(obj_constructor, "values", N_OBJ_VALUES);
    installNativeMethod(obj_constructor, "entries", N_OBJ_ENTRIES);
    installNativeMethod(obj_constructor, "assign", N_OBJ_ASSIGN);
    installNativeMethod(obj_constructor, "create", N_OBJ_CREATE);
    installNativeMethod(obj_constructor, "defineProperty", N_OBJ_DEFINE_PROP);
    installNativeMethod(obj_constructor, "getOwnPropertyDescriptor", N_OBJ_GET_OWN_DESC);
    installNativeMethod(obj_constructor, "freeze", N_OBJ_FREEZE);
    installNativeMethod(obj_constructor, "isFrozen", N_OBJ_IS_FROZEN);
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
    const bool_ctor = objects.createFunction(N_BOOLEAN_CTOR);
    objects.setProperty(bool_ctor, values.internString("prototype"), Value.object(objects.getBooleanProto()));
    objects.setEnumerable(bool_ctor, values.internString("prototype"), false);
    objects.setProperty(objects.getBooleanProto(), values.internString("constructor"), Value.function(bool_ctor));
    objects.setEnumerable(objects.getBooleanProto(), values.internString("constructor"), false);
    objects.setProperty(global, values.internString("Boolean"), Value.function(bool_ctor));

    // Date — callable (Date() / new Date()) with static Date.now().
    const date_ctor = objects.createFunction(N_DATE_CTOR);
    installNativeMethod(date_ctor, "now", N_DATE_NOW);
    date_proto = objects.createObject();
    installNativeMethod(date_proto, "getTime", N_DATE_VALUE_OF);
    installNativeMethod(date_proto, "valueOf", N_DATE_VALUE_OF);
    installNativeMethod(date_proto, "getHours", N_DATE_HOURS);
    installNativeMethod(date_proto, "getMinutes", N_DATE_MINUTES);
    installNativeMethod(date_proto, "getTimezoneOffset", N_DATE_ZONE_OFFSET);
    installNativeMethod(date_proto, "toString", N_DATE_TOSTRING);
    objects.setProperty(date_ctor, values.internString("prototype"), Value.object(date_proto));
    objects.setProperty(date_proto, values.internString("constructor"), Value.function(date_ctor));
    objects.setEnumerable(date_proto, values.internString("constructor"), false);
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
            objects.setProperty(func_ctor.data.func_idx, values.internString("prototype"), Value.function(objects.getFunctionProto()));
            objects.setEnumerable(func_ctor.data.func_idx, values.internString("prototype"), false);
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
    installNativeMethod(objects.getFunctionProto(), "call", N_FN_CALL);
    installNativeMethod(objects.getFunctionProto(), "apply", N_FN_APPLY);
    installNativeMethod(objects.getFunctionProto(), "bind", N_FN_BIND);
    objects.getObject(objects.getFunctionProto()).func_id = N_FUNCTION_PROTO;
    for ([_][]const u8{"name", "length"}) |name| {
        const key = values.internString(name);
        objects.setProperty(objects.getFunctionProto(), key, if (eql(name,"name")) Value.string(values.internString("")) else Value.number(0));
        objects.setEnumerable(objects.getFunctionProto(), key, false);
        objects.setWritable(objects.getFunctionProto(), key, false);
    }





    // Constants
    objects.setProperty(global, values.internString("undefined"), Value.UNDEFINED);
    objects.setProperty(global, values.internString("NaN"), Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000)))));
    objects.setProperty(global, values.internString("Infinity"), Value.number(@as(f64, @bitCast(@as(u64, 0x7FF0000000000000)))));
    for ([_][]const u8{"Object", "Array", "String", "Number", "Boolean", "RegExp", "Date", "Error", "ReferenceError", "TypeError"}) |name| {
        const constructor = objects.getProperty(global, values.internString(name));
        if (constructor.tag != .function) continue;
        setNativeFunctionMetadata(constructor.data.func_idx, name, nativeArity(objects.closureFuncId(constructor.data.func_idx)));
        objects.setEnumerable(constructor.data.func_idx, values.internString("prototype"), false);
        objects.setWritable(constructor.data.func_idx, values.internString("prototype"), false);
    }
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
    installNativeMethod(ap, "reverse", N_ARR_REVERSE);
    installNativeMethod(ap, "sort", N_ARR_SORT);
    installNativeMethod(ap, "toString", N_ARR_TOSTRING);
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
            installNativeMethod(np, "valueOf", N_NUMBER_VALUE_OF);
        }
        installNativeMethod(objects.getBooleanProto(), "valueOf", N_BOOLEAN_VALUE_OF);
        installNativeMethod(objects.getBooleanProto(), "toString", N_BOOLEAN_TOSTRING);
    }
}

// ── Call Native ──

/// Dispatch a native function call.
/// A native builtin can request the VM raise a TypeError by setting this flag +
/// message; the VM checks it after callNative and throws (JS-correct). Used by
/// String.prototype.toString/valueOf when `this` is not a String.
pub var native_throw: bool = false;
pub var native_throw_name: []const u8 = "TypeError";
pub var string_conversion: ?*const fn (Value) u32 = null;
pub var native_throw_msg_buf: [160]u8 = undefined;
pub var native_throw_msg_len: usize = 0;
pub fn nativeThrowMsg() []const u8 { return native_throw_msg_buf[0..native_throw_msg_len]; }
fn requestNativeThrow(msg: []const u8) void {
    native_throw = true;
    native_throw_name = "TypeError";
    const n = @min(msg.len, native_throw_msg_buf.len);
    @memcpy(native_throw_msg_buf[0..n], msg[0..n]);
    native_throw_msg_len = n;
}

fn requestRangeError(msg: []const u8) void {
    requestNativeThrow(msg);
    native_throw_name = "RangeError";
}

/// String.prototype.toString / valueOf. `this` (args[0]) must be a primitive
/// string (or a String wrapper). Otherwise JS throws a TypeError.
fn strToStringMethod(args: []const Value) Value {
    if (args.len > 0 and args[0].tag == .string) return args[0];
    if (args.len > 0 and args[0].tag == .object and objects.objTypeOf(args[0].data.obj_idx) == .boxed_string) return Value.string(objects.getObject(args[0].data.obj_idx).array_start);
    requestNativeThrow("String.prototype.toString requires that 'this' be a String");
    return Value.UNDEFINED;
}

pub fn callNative(func_id: u16, args: []const Value, argc: u8) Value {
    if (callbackAborted()) return Value.UNDEFINED;
    // Generic string methods apply RequireObjectCoercible and ToString.
    // toString/valueOf use their stricter String brand check below.
    if (func_id >= N_STR_CHAR_AT and func_id <= N_STR_MATCH and func_id != N_STR_TOSTRING and args.len > 0 and args[0].tag != .string) {
        if (args[0].tag == .null_val or args[0].tag == .undefined) { requestNativeThrow("String method called on null or undefined"); return Value.UNDEFINED; }
        var normalized: [256]Value = undefined;
        if (args.len > normalized.len) { requestRangeError("String argument capacity exceeded"); return Value.UNDEFINED; }
        @memcpy(normalized[0..args.len], args);
        normalized[0] = stringCtor(&.{args[0]});
        return callNative(func_id, normalized[0..args.len], argc);
    }
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
        N_MATH_ATAN2 => mathAtan2(args),
        N_PARSE_INT => nParseInt(args),
        N_PARSE_FLOAT => nParseFloat(args),
        N_IS_NAN => if (args.len > 0) boolVal(args[0].toNumber() != args[0].toNumber()) else Value.TRUE,
        N_IS_FINITE => nIsFinite(args),
        N_ATOB => nAtob(args),
        N_BTOA => nBtoa(args),
        N_SET_TIMEOUT => enqueueTask(args, false, false),
        N_SET_INTERVAL => enqueueTask(args, true, false),
        N_CLEAR_TIMEOUT => cancelTask(args),
        N_QUEUE_MICROTASK => enqueueTask(args, false, true),
        N_CONSOLE_LOG => nConsoleLog(args),
        N_STR_FROM_CHARCODE => strFromCharCode(args),
        N_STR_CHAR_AT => strCharAt(args),
        N_STR_CHAR_CODE_AT => strCharCodeAt(args),
        N_STR_INDEX_OF => strIndexOf(args),
        N_STR_SLICE => strSlice(args),
        N_STR_SUBSTRING => strSubstring(args),
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
        N_ARR_TOSTRING => arrToString(args),
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
        N_OBJ_OWN_NAMES => objOwnNames(args),
        N_OBJ_ASSIGN => objAssign(args),
        N_OBJ_CREATE => objCreate(args),
        N_OBJ_FREEZE => objFreeze(args),
        N_OBJ_IS_FROZEN => if (args.len == 0 or (args[0].tag != .object and args[0].tag != .array and args[0].tag != .function)) Value.TRUE else boolVal(objects.isFrozen(args[0].data.obj_idx)),
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
        N_NUMBER_VALUE_OF => numberValue(args),
        N_BOOLEAN_CTOR => boolVal(args.len > 0 and args[0].isTruthy()),
        N_FUNCTION_PROTO => Value.UNDEFINED,
        N_BOOLEAN_VALUE_OF => booleanValue(args),
        N_BOOLEAN_TOSTRING => blk: { const v = booleanValue(args); if (native_throw) break :blk Value.UNDEFINED; break :blk Value.string(values.internString(if (v.data.boolean != 0) "true" else "false")); },
        N_STRING_CTOR => stringCtor(args),
        N_OBJECT_CTOR => objectCtor(args),
        N_DATE_CTOR => dateStringFromTime(dateNow().toNumber()), // Calling Date ignores arguments; new Date uses constructDate.
        N_DATE_TOSTRING => dateString(if (args.len > 0) args[0] else Value.UNDEFINED),
        N_DATE_VALUE_OF => if (args.len > 0 and args[0].tag == .object and objects.objTypeOf(args[0].data.obj_idx) == .date) Value.number(objects.getObject(args[0].data.obj_idx).number_value) else Value.number(dateNaN()),
        N_DATE_HOURS, N_DATE_MINUTES, N_DATE_ZONE_OFFSET => dateLocalPart(args, func_id),
        N_ERROR_CTOR => makeErrorVal("Error", args),
        N_REFERROR_CTOR => makeErrorVal("ReferenceError", args),
        N_TYPEERROR_CTOR => makeErrorVal("TypeError", args),
        N_ERROR_TOSTRING => errorToString(args),
        N_DOM_CREATE_ELEMENT => makeDomElement(args),
        N_DOM_CREATE_TEXT => makeDomCharacter(args, 3),
        N_DOM_CREATE_COMMENT => makeDomCharacter(args, 8),
        N_DOM_NOOP => Value.UNDEFINED,
        N_DOM_EMPTY_OBJECT => Value.object(objects.createObject()),
        N_EVENT_ADD => eventListen(args, false),
        N_EVENT_REMOVE => eventListen(args, true),
        N_EVENT_DISPATCH => eventDispatch(args),
        N_DOM_CLICK => domClick(args),
        N_EVENT_CTOR => makeEvent(args),
        N_EVENT_PREVENT => eventPrevent(args),
        N_EVENT_STOP_IMMEDIATE => eventStopImmediate(args),
        N_DOM_REPLACE_CHILD => domInsert(args, true),
        N_DOM_INSERT_BEFORE => domInsert(args, false),
        N_DOM_APPEND => domAppend(args),
        N_DOM_REMOVE => domRemove(args),
        N_DOM_FRAME_LOAD => domFrameLoad(args),
        N_DOM_LOOKUP_NAMESPACE => domLookupNamespace(args),
        N_DOM_FALSE => Value.FALSE,
        N_NAV_WEBDRIVER => navigatorWebdriver(args),
        N_DOM_IMAGE => makeDomElement(&.{Value.string(values.internString("img"))}),
        N_DOM_EMPTY_STRING => Value.string(values.internString("")),
        N_MEDIA_CAN_PLAY => mediaCanPlay(args),
        N_IFRAME_WINDOW, N_IFRAME_DOCUMENT, N_IFRAME_SRCDOC, N_IFRAME_SET_SRCDOC => iframeProperty(func_id, args),
        N_DOC_HAS_FOCUS => documentHasFocus(args),
        N_DOM_MATCH_MEDIA => makeMediaQueryList(args),
        N_DOM_ORIENTATION_EVENT => makeOrientationEvent(args),
        N_DOM_RECT => makeDomRect(),
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
        N_INT8_ARRAY => blk: {
            const result = createTypedArrayN(args, 1);
            if (result.tag == .object) objects.getObject(result.data.obj_idx).elem_signed = true;
            break :blk result;
        },
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
            if (objects.getObject(recv.data.obj_idx).dom_window) break :blk "[object Window]";
            const ot = objects.getObject(recv.data.obj_idx).obj_type;
            break :blk if (objects.isArguments(recv.data.obj_idx)) "[object Arguments]" else if (ot == .array) "[object Array]" else if (ot == .function) "[object Function]" else if (ot == .regexp) "[object RegExp]" else if (ot == .date) "[object Date]" else if (ot == .boxed_string) "[object String]" else if (ot == .boxed_number) "[object Number]" else if (ot == .boxed_boolean) "[object Boolean]" else "[object Object]";
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
    if (v.tag == .object or v.tag == .array or v.tag == .function) {
        if (string_conversion) |convert| return Value.string(convert(v));
    }
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
    if (args.len > 0 and args[0].tag == .string) return Value.object(objects.createStringWrapper(args[0].data.str_idx));
    if (args.len > 0 and args[0].tag == .number) return Value.object(objects.createNumberWrapper(args[0].data.number));
    if (args.len > 0 and args[0].tag == .boolean) return Value.object(objects.createBooleanWrapper(args[0].data.boolean != 0));
    return Value.object(objects.createObject());
}

pub fn constructString(args: []const Value) Value {
    const text = stringCtor(args);
    if (native_throw) return Value.UNDEFINED;
    return Value.object(objects.createStringWrapper(text.data.str_idx));
}
pub fn constructNumber(args: []const Value) Value {
    const n = if (args.len > 0) args[0].toNumber() else 0;
    if (callbackAborted()) return Value.UNDEFINED;
    return Value.object(objects.createNumberWrapper(n));
}
pub fn constructBoolean(args: []const Value) Value {
    return Value.object(objects.createBooleanWrapper(args.len > 0 and args[0].isTruthy()));
}
fn numberValue(args: []const Value) Value {
    if (args.len > 0) {
        const v = args[0];
        if (v.tag == .number) return v;
        if (v.tag == .object and objects.objTypeOf(v.data.obj_idx) == .boxed_number) return Value.number(objects.getObject(v.data.obj_idx).number_value);
    }
    requestNativeThrow("Number method requires that 'this' be a Number");
    return Value.UNDEFINED;
}
fn booleanValue(args: []const Value) Value {
    if (args.len > 0) {
        const v = args[0];
        if (v.tag == .boolean) return v;
        if (v.tag == .object and objects.objTypeOf(v.data.obj_idx) == .boxed_boolean) return boolVal(objects.getObject(v.data.obj_idx).array_start != 0);
    }
    requestNativeThrow("Boolean method requires that 'this' be a Boolean");
    return Value.UNDEFINED;
}

/// Minimal number→decimal string (integers exact; fractional best-effort) for
/// String(number). Returns bytes written.
fn numberToDecimal(n: f64, buf: *[40]u8) usize { return values.numberToString(n, buf); }

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
                    if (callbackAborted()) return values.internString("");
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
        if (objects.arrayIndexName(name)) |index| return boolVal(index < values.getStringUnitLength(recv.data.str_idx));
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
        if (objects.arrayIndexName(values.getString(name_idx))) |index| return boolVal(index < values.getStringUnitLength(recv.data.str_idx));
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

fn atanPositive(input: f64) f64 {
    const inverted = input > 1;
    var x = if (inverted) 1 / input else input;
    const shifted = x > 0.41421356237309503;
    if (shifted) x = (x - 1) / (x + 1);
    const square = x * x;
    var term = x;
    var sum = x;
    var i: u32 = 1;
    while (i < 40) : (i += 1) {
        term *= -square;
        sum += term / @as(f64, @floatFromInt(2 * i + 1));
    }
    if (shifted) sum += 0.7853981633974483;
    return if (inverted) 1.5707963267948966 - sum else sum;
}

fn mathAtan2(args: []const Value) Value {
    const nan = @as(f64, @bitCast(@as(u64, 0x7FF8000000000000)));
    if (args.len < 2) return Value.number(nan);
    const y = args[0].toNumber();
    const x = args[1].toNumber();
    if (x != x or y != y) return Value.number(nan);
    const negative_y = (@as(u64, @bitCast(y)) >> 63) != 0;
    const negative_x = (@as(u64, @bitCast(x)) >> 63) != 0;
    const ax = @abs(x);
    const ay = @abs(y);
    const infinity = @as(f64, @bitCast(@as(u64, 0x7FF0000000000000)));
    var angle: f64 = 0;
    if (ay == 0) {
        angle = if (negative_x) 3.141592653589793 else 0;
    } else if (ax == 0) {
        angle = 1.5707963267948966;
    } else if (ax == infinity and ay == infinity) {
        angle = if (negative_x) 2.356194490192345 else 0.7853981633974483;
    } else {
        angle = atanPositive(ay / ax);
        if (negative_x) angle = 3.141592653589793 - angle;
    }
    return Value.number(if (negative_y) -angle else angle);
}

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
    if (args.len < 2 or (!objectValue(args[1]) and args[1].tag != .null_val)) {
        requestNativeThrow("Object prototype must be an object or null"); return Value.UNDEFINED;
    }
    const o = objects.createObject();
    objects.setObjectPrototype(o, if (args[1].tag == .null_val) objects.NULL_OBJ else args[1].data.obj_idx);
    if (args.len >= 3 and args[2].tag != .undefined) {
        if (args[2].tag == .null_val) { requestNativeThrow("Property descriptors cannot be null"); return Value.UNDEFINED; }
        const props = objectCtor(&.{args[2]});
        if (!applyPropertyDescriptors(o, props)) return Value.UNDEFINED;
    }
    return Value.object(o);
}

/// Object.create uses the same descriptor conversion/definition rules as
/// Object.defineProperty. Its fresh target is not exposed before all entries
/// succeed; getter side effects and failures still follow property-key order.
fn applyPropertyDescriptors(target: u32, props: Value) bool {
    var keys: [objects.MAX_ENUM_KEYS]u32 = undefined;
    const count = objects.enumerateOwnKeys(props.data.obj_idx, &keys, true);
    if (count == keys.len) { requestRangeError("Property descriptor capacity exceeded"); return false; }
    for (keys[0..count]) |key| {
        // A previous descriptor getter can remove a later property or make it
        // nonenumerable after the initial key snapshot.
        var own: objects.Property = undefined;
        if (!objects.ownPropertyDescriptor(props.data.obj_idx, key, &own) or !own.flags.enumerable) continue;
        const desc = descriptorField(props, key);
        if (native_throw or callbackAborted()) return false;
        _ = objDefineProperty(&.{Value.UNDEFINED, Value.object(target), Value.string(key), desc});
        if (native_throw or callbackAborted()) return false;
    }
    return true;
}

// WebIDL attribute getters require an actual interface instance. A forged
// prototype chain or a detached invocation cannot supply its internal slots.
fn navigatorWebdriver(args: []const Value) Value {
    if (args.len > 0 and args[0].tag == .object and objects.getObject(args[0].data.obj_idx).dom_navigator) return Value.FALSE;
    requestNativeThrow("Illegal invocation");
    return Value.UNDEFINED;
}

fn objGetProto(args: []const Value) Value {
    if (args.len >= 2 and (args[1].tag == .object or args[1].tag == .array or args[1].tag == .function)) {
        const p = objects.getObjectPrototypeIdx(@intCast(args[1].data.obj_idx));
        if (p != objects.NULL_OBJ) return if (objects.objTypeOf(p) == .function) Value.function(p) else Value.object(p);
    }
    return Value.NULL;
}

fn objFreeze(args: []const Value) Value {
    const target = if (args.len > 0) args[0] else Value.UNDEFINED;
    if (target.tag == .object or target.tag == .array or target.tag == .function) objects.freezeObject(target.data.obj_idx);
    return target;
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
        objects.setProperty(desc, values.internString("set"), if (prop.flags.is_setter) Value.function(prop.setter_fn) else Value.UNDEFINED);
    } else {
        objects.setProperty(desc, values.internString("value"), prop.value);
        objects.setProperty(desc, values.internString("writable"), if (prop.flags.writable) Value.TRUE else Value.FALSE);
    }
    objects.setProperty(desc, values.internString("enumerable"), if (prop.flags.enumerable) Value.TRUE else Value.FALSE);
    objects.setProperty(desc, values.internString("configurable"), if (prop.flags.configurable) Value.TRUE else Value.FALSE);
    return Value.object(desc);
}

fn objDefineProperty(args: []const Value) Value {
    if (args.len < 4 or !objectValue(args[1]) or !objectValue(args[3])) { requestNativeThrow("Object.defineProperty requires object arguments"); return Value.UNDEFINED; }
    const target = args[1]; const desc = args[3];
    const key_idx = keyNameIdx(args[2]);
    if (callbackAborted() or native_throw) return Value.UNDEFINED;
    // ToPropertyDescriptor reads inherited fields and invokes accessors in the
    // specified order. Complete the conversion before changing the target.
    var present: [6]bool = undefined;
    var fields: [6]Value = undefined;
    for ([_][]const u8{"enumerable", "configurable", "value", "writable", "get", "set"}, 0..) |name, i| {
        const field_key = values.internString(name);
        present[i] = hasDescriptorField(desc.data.obj_idx, field_key);
        fields[i] = if (present[i]) descriptorField(desc, field_key) else Value.UNDEFINED;
        if (callbackAborted() or native_throw) return Value.UNDEFINED;
    }
    const accessor = present[4] or present[5];
    const data = present[2] or present[3];
    if (accessor and data) { requestNativeThrow("Accessor descriptor cannot contain value or writable"); return Value.UNDEFINED; }
    for (fields[4..6]) |function| if (function.tag != .undefined and function.tag != .function) { requestNativeThrow("Accessor getter and setter must be functions or undefined"); return Value.UNDEFINED; };
    var previous: objects.Property = undefined;
    const existed = objects.ownPropertyDescriptor(target.data.obj_idx, key_idx, &previous);
    var property = if (existed) previous else objects.Property{ .name_idx = key_idx, .value = Value.UNDEFINED, .flags = .{ .writable = false, .enumerable = false, .configurable = false } };
    if (present[0]) property.flags.enumerable = fields[0].isTruthy();
    if (present[1]) property.flags.configurable = fields[1].isTruthy();
    const conversion = existed and (accessor or data) and accessor != previous.flags.is_getter;
    if (conversion) { property.value = Value.UNDEFINED; property.setter_fn = objects.NULL_OBJ; property.flags.writable = false; property.flags.is_getter = false; property.flags.is_setter = false; }
    if (accessor) {
        property.flags.is_getter = true; property.flags.writable = false;
        if (present[4]) property.value = fields[4];
        if (present[5]) { property.setter_fn = if (fields[5].tag == .function) fields[5].data.func_idx else objects.NULL_OBJ; property.flags.is_setter = fields[5].tag == .function; }
    } else if (data) {
        if (present[2]) property.value = fields[2];
        if (present[3]) property.flags.writable = fields[3].isTruthy();
    }
    if (existed and !previous.flags.configurable) {
        var invalid = property.flags.configurable or property.flags.enumerable != previous.flags.enumerable or conversion;
        if (previous.flags.is_getter) {
            invalid = invalid or !sameDescriptorValue(previous.value, property.value) or previous.setter_fn != property.setter_fn;
        } else if (!previous.flags.writable) invalid = invalid or property.flags.writable or !sameDescriptorValue(previous.value, property.value);
        if (invalid) { requestNativeThrow("Cannot redefine a non-configurable property"); return Value.UNDEFINED; }
    }
    if (objects.objTypeOf(target.data.obj_idx) == .array and eql(values.getString(key_idx), "length")) {
        const length = property.value.toNumber();
        if (callbackAborted()) return Value.UNDEFINED;
        if (length != length or length < 0 or length > 4294967295 or @trunc(length) != length) { requestNativeThrow("Invalid array length"); native_throw_name = "RangeError"; return Value.UNDEFINED; }
        property.value = Value.number(length);
    }
    if (!objects.defineOwnProperty(target.data.obj_idx, property)) { requestNativeThrow("Cannot define property"); return Value.UNDEFINED; }
    return target;
}
fn objectValue(value: Value) bool { return value.tag == .object or value.tag == .array or value.tag == .function; }
fn hasDescriptorField(object: u32, key: u32) bool {
    var current = object; var depth: usize = 0;
    while (current != objects.NULL_OBJ and depth < 32) : (depth += 1) {
        if (objects.hasOwnProperty(current, key)) return true;
        current = objects.getObject(current).prototype;
    }
    return false;
}
fn descriptorField(receiver: Value, key: u32) Value {
    var getter = Value.UNDEFINED;
    if (objects.getPropertyGetter(receiver.data.obj_idx, key, &getter)) {
        if (getter.tag == .function) { if (invoke_callback) |invoke| return invoke(getter, receiver, &.{}); }
        return Value.UNDEFINED;
    }
    return objects.getProperty(receiver.data.obj_idx, key);
}
fn sameDescriptorValue(a: Value, b: Value) bool {
    if (objectValue(a) and objectValue(b)) return a.data.obj_idx == b.data.obj_idx;
    if (a.tag != b.tag) return false;
    return switch (a.tag) {
        .number => (a.data.number != a.data.number and b.data.number != b.data.number) or (a.data.number == b.data.number and (a.data.number != 0 or @as(u64, @bitCast(a.data.number)) == @as(u64, @bitCast(b.data.number)))),
        .string, .symbol => a.data.str_idx == b.data.str_idx,
        .boolean => a.data.boolean == b.data.boolean,
        .undefined, .null_val => true,
        else => false,
    };
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

fn numToDecimal(n: f64, buf: []u8) usize { return values.numberToString(n, buf); }

// ── DOM element stub ──

/// document.createElement(tag) -> a generic element object with the common
/// methods/props BotGuard touches (style, setAttribute, appendChild, and — for
/// canvas — getContext). Matches the minimal element that lets BotGuard run its
/// success path (verified against the Node reference).
pub fn makeDomStyle() u32 {
    if (dom_style_proto == objects.NULL_OBJ) {
        dom_style_proto = objects.createObject();
        browser_metadata.installMissing(dom_style_proto, &browser_metadata.style_fields, N_DOM_NOOP);
    }
    const style = objects.createObject();
    objects.setObjectPrototype(style, dom_style_proto);
    return style;
}

/// The fixed browser host has no active CSS media evaluator. Return the
/// standard object with a conservative non-match instead of undefined.
fn makeMediaQueryList(args: []const Value) Value {
    const result = objects.createObject();
    objects.setProperty(result, values.internString("matches"), Value.FALSE);
    objects.setProperty(result, values.internString("media"), if (args.len > 0) Value.string(keyNameIdx(args[args.len - 1])) else Value.string(values.internString("undefined")));
    objects.setProperty(result, values.internString("onchange"), Value.NULL);
    for ([_][]const u8{ "addListener", "removeListener", "addEventListener", "removeEventListener" }) |name| installNativeMethod(result, name, N_DOM_NOOP);
    installNativeMethod(result, "dispatchEvent", N_DOM_FALSE);
    return Value.object(result);
}

fn makeDomElement(args: []const Value) Value {
    const el = objects.createObject();
    registerDomNode(el, 1);
    if (dom_element_proto != objects.NULL_OBJ) objects.setObjectPrototype(el, dom_element_proto);
    const style = makeDomStyle();
    objects.setProperty(el, values.internString("style"), Value.object(style));
    objects.setProperty(style, values.internString("textEmphasisColor"), Value.string(values.internString("")));
    objects.setProperty(style, values.internString("webkitTransition"), Value.string(values.internString("")));
    installNativeMethod(el, "before", N_DOM_NOOP);
    installNativeMethod(el, "normalize", N_DOM_NOOP);
    installNativeMethod(el, "setAttribute", N_DOM_NOOP);
    installNativeMethod(el, "getAttribute", N_DOM_NOOP);
    installNativeMethod(el, "removeAttribute", N_DOM_NOOP);
    installNativeMethod(el, "hasAttribute", N_DOM_FALSE);
    installNativeMethod(el, "click", N_DOM_CLICK);
    installNativeMethod(el, "matches", N_DOM_FALSE);
    if (args.len > 0 and args[args.len - 1].tag == .string) {
        const tag = values.getString(args[args.len - 1].data.str_idx);
        if (std.ascii.eqlIgnoreCase(tag, "audio") or std.ascii.eqlIgnoreCase(tag, "video")) {
            objects.getObject(el).dom_media = true;
            const ctor = objects.getProperty(g_global_obj, values.internString("HTMLMediaElement"));
            if (ctor.tag == .function) {
                const proto = objects.getProperty(ctor.data.func_idx, values.internString("prototype"));
                if (proto.tag == .object) objects.setObjectPrototype(el, proto.data.obj_idx);
            }
            installNativeMethod(el, "canPlayType", N_MEDIA_CAN_PLAY);
        }
    }
    installNativeMethod(el, "getBoundingClientRect", N_DOM_RECT);
    installNativeMethod(el, "appendChild", N_DOM_APPEND);
    installNativeMethod(el, "removeChild", N_DOM_REMOVE);
    installNativeMethod(el, "replaceChild", N_DOM_REPLACE_CHILD);
    installNativeMethod(el, "insertBefore", N_DOM_INSERT_BEFORE);
    installNativeMethod(el, "lookupNamespaceURI", N_DOM_LOOKUP_NAMESPACE);
    objects.setProperty(el, values.internString("namespaceURI"), Value.string(values.internString("http://www.w3.org/1999/xhtml")));
    if (args.len > 0 and args[args.len - 1].tag == .string and eql(values.getString(args[args.len - 1].data.str_idx), "img"))
        objects.setProperty(el, values.internString("isMap"), Value.FALSE);
    installNativeMethod(el, "addEventListener", N_EVENT_ADD);
    installNativeMethod(el, "removeEventListener", N_EVENT_REMOVE);
    installNativeMethod(el, "dispatchEvent", N_EVENT_DISPATCH);
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
    objects.setProperty(el, values.internString("offsetHeight"), Value.number(0));
    if (args.len > 0 and args[args.len - 1].tag == .string) {
        const tag = values.getString(args[args.len - 1].data.str_idx);
        if (eql(tag, "MouseEvent") or eql(tag, "MouseEvents") or eql(tag, "UIEvent") or eql(tag, "UIEvents"))
            browser_metadata.installMissing(el, &browser_metadata.event_fields, N_DOM_NOOP);
    }
    // iframe realm access: BotGuard creates an iframe and reads
    // `iframe.contentWindow` to get a fresh realm's pristine `String`/`eval`
    // (anti-tamper). jsdom returns a real Window; we return the global object
    // (which carries String/Object/eval/etc.). Also expose contentDocument.
    if (g_global_obj != 0 and args.len > 0 and args[args.len-1].tag == .string and std.ascii.eqlIgnoreCase(values.getString(args[args.len-1].data.str_idx), "iframe")) {
        objects.getObject(el).dom_iframe = true;
        const ctor = objects.getProperty(g_global_obj, values.internString("HTMLIFrameElement"));
        if (ctor.tag == .function) {
            const proto = objects.getProperty(ctor.data.func_idx, values.internString("prototype"));
            if (proto.tag == .object) objects.setObjectPrototype(el, proto.data.obj_idx);
        }
    }
    return Value.object(el);
}

fn domLookupNamespace(args: []const Value) Value {
    if (args.len < 2 or args[1].tag == .null_val or args[1].tag == .undefined or (args[1].tag == .string and values.getString(args[1].data.str_idx).len == 0)) {
        if (args.len > 0 and args[0].tag == .object)
            return objects.getProperty(args[0].data.obj_idx, values.internString("namespaceURI"));
    }
    return Value.NULL;
}

fn eventListen(args: []const Value, remove: bool) Value {
    if (args.len < 3 or args[0].tag != .object) { requestNativeThrow("EventTarget requires a receiver, type and listener"); return Value.UNDEFINED; }
    const kind = stringCtor(args[1..2]);
    if (callbackAborted()) return Value.UNDEFINED;
    const callback = args[2];
    if (callback.tag == .undefined or callback.tag == .null_val) return Value.UNDEFINED;
    if (callback.tag != .function and callback.tag != .object and callback.tag != .array) { requestNativeThrow("Event listener must be an object or function"); return Value.UNDEFINED; }
    const options = if (args.len > 3) args[3] else Value.FALSE;
    if (remove) events.remove(args[0].data.obj_idx, kind.data.str_idx, callback, options)
    else if (!events.add(args[0].data.obj_idx, kind.data.str_idx, callback, options)) requestRangeError("Event listener capacity exceeded");
    return Value.UNDEFINED;
}
fn mediaCanPlay(args: []const Value) Value {
    if (args.len == 0 or args[0].tag != .object or !objects.getObject(args[0].data.obj_idx).dom_media) {
        requestNativeThrow("canPlayType requires an HTMLMediaElement receiver"); return Value.UNDEFINED;
    }
    if (args.len < 2) { requestNativeThrow("canPlayType requires a media type"); return Value.UNDEFINED; }
    _ = stringCtor(args[1..2]);
    if (callbackAborted()) return Value.UNDEFINED;
    // No decoder is attached to this embedded host. Its codec capability
    // response is the standard empty string, independently of the input type.
    return Value.string(values.internString(""));
}
fn iframeProperty(id: u16, args: []const Value) Value {
    if (args.len == 0 or args[0].tag != .object or !objects.getObject(args[0].data.obj_idx).dom_iframe) {
        requestNativeThrow("Iframe property requires an HTMLIFrameElement receiver"); return Value.UNDEFINED;
    }
    const element = objects.getObject(args[0].data.obj_idx);
    if (id == N_IFRAME_WINDOW) {
        dbg_iframe_reads += 1;
        if (element.dom_iframe_window != objects.NULL_OBJ) return Value.object(element.dom_iframe_window);
        const window = objects.createObject();
        if (window == objects.NULL_OBJ or !objects.copyOwnProperties(dom_window_template, window)) {
            requestRangeError("Iframe window storage exceeded"); return Value.UNDEFINED;
        }
        objects.getObject(window).dom_window = true;
        for ([_][]const u8{ "window", "self", "globalThis" }) |key|
            objects.setProperty(window, values.internString(key), Value.object(window));
        for ([_][]const u8{ "parent", "top" }) |key|
            objects.setProperty(window, values.internString(key), Value.object(g_global_obj));
        objects.setProperty(window, values.internString("frameElement"), args[0]);
        element.dom_iframe_window = window;
        return Value.object(window);
    }
    if (id == N_IFRAME_DOCUMENT) return objects.getProperty(g_global_obj, values.internString("document"));
    if (id == N_IFRAME_SET_SRCDOC) {
        const value = stringCtor(if (args.len > 1) args[1..2] else &.{Value.UNDEFINED});
        if (!callbackAborted()) element.dom_srcdoc = value.data.str_idx;
        return Value.UNDEFINED;
    }
    return Value.string(if (element.dom_srcdoc == objects.NULL_OBJ) values.internString("") else element.dom_srcdoc);
}
fn documentHasFocus(args: []const Value) Value {
    if (args.len == 0 or args[0].tag != .object or args[0].data.obj_idx != dom_document_obj) {
        requestNativeThrow("hasFocus requires a Document receiver"); return Value.UNDEFINED;
    }
    return Value.FALSE;
}

fn makeDomCharacter(args: []const Value, kind: u8) Value {
    const data = stringCtor(if (args.len > 0) args[args.len-1..] else &.{Value.UNDEFINED});
    if (callbackAborted()) return Value.UNDEFINED;
    const node = objects.createObject();
    registerDomNode(node, kind);
    objects.setProperty(node, values.internString("data"), data);
    objects.setProperty(node, values.internString("nodeValue"), data);
    objects.setProperty(node, values.internString("textContent"), data);
    objects.setProperty(node, values.internString("nodeName"), Value.string(values.internString(if (kind == 3) "#text" else "#comment")));
    return Value.object(node);
}

pub fn registerDomNode(node: u32, kind: u8) void {
    const object = objects.getObject(node);
    object.dom_node = true;
    object.dom_node_kind = kind;
    object.dom_children = objects.createArray(0);
    objects.setProperty(node, values.internString("nodeType"), Value.number(@floatFromInt(kind)));
    objects.setWritable(node, values.internString("nodeType"), false);
    objects.setProperty(node, values.internString("parentNode"), Value.NULL);
    objects.setProperty(node, values.internString("childNodes"), Value.object(object.dom_children));
    objects.setProperty(node, values.internString("firstChild"), Value.NULL);
    objects.setProperty(node, values.internString("lastChild"), Value.NULL);
    if (kind == 1 or kind == 9 or kind == 11) {
        // A live element-only collection, distinct from childNodes and from
        // JavaScript Array. Reuse its identity when nodes move or disappear.
        const collection = objects.createObject();
        object.dom_element_children = collection;
        objects.setProperty(collection, values.internString("length"), Value.number(0));
        objects.setEnumerable(collection, values.internString("length"), false);
        objects.setWritable(collection, values.internString("length"), false);
        objects.setProperty(node, values.internString("children"), Value.object(collection));
        objects.setWritable(node, values.internString("children"), false);
        objects.setProperty(node, values.internString("childElementCount"), Value.number(0));
        objects.setProperty(node, values.internString("firstElementChild"), Value.NULL);
        objects.setProperty(node, values.internString("lastElementChild"), Value.NULL);
    }
}
fn syncDomChildren(parent: u32) void {
    const array = objects.getObject(parent).dom_children;
    const len = objects.arrayLength(array);
    objects.setProperty(parent, values.internString("firstChild"), if (len == 0) Value.NULL else objects.getArrayElement(array, 0));
    objects.setProperty(parent, values.internString("lastChild"), if (len == 0) Value.NULL else objects.getArrayElement(array, len-1));
    const collection = objects.getObject(parent).dom_element_children;
    if (collection == objects.NULL_OBJ) return;
    const length_key = values.internString("length");
    const old_length: u32 = @intFromFloat(objects.getProperty(collection, length_key).toNumber());
    var count: u32 = 0;
    var first = Value.NULL;
    var last = Value.NULL;
    for (0..len) |i| {
        const child = objects.getArrayElement(array, @intCast(i));
        if (child.tag != .object or objects.getObject(child.data.obj_idx).dom_node_kind != 1) continue;
        var key_buf: [40]u8 = undefined;
        const key_len = values.numberToString(@floatFromInt(count), &key_buf);
        const key = values.internString(key_buf[0..key_len]);
        objects.setWritable(collection, key, true);
        objects.setProperty(collection, key, child);
        objects.setWritable(collection, key, false);
        if (count == 0) first = child;
        last = child;
        count += 1;
    }
    var i = count;
    while (i < old_length) : (i += 1) {
        var key_buf: [40]u8 = undefined;
        const key_len = values.numberToString(@floatFromInt(i), &key_buf);
        objects.deleteProperty(collection, values.internString(key_buf[0..key_len]));
    }
    objects.setWritable(collection, length_key, true);
    objects.setProperty(collection, length_key, Value.number(@floatFromInt(count)));
    objects.setWritable(collection, length_key, false);
    objects.setProperty(parent, values.internString("childElementCount"), Value.number(@floatFromInt(count)));
    objects.setProperty(parent, values.internString("firstElementChild"), first);
    objects.setProperty(parent, values.internString("lastElementChild"), last);

}
fn detachDomChild(parent: u32, child: u32) bool {
    const array = objects.getObject(parent).dom_children;
    const len = objects.arrayLength(array);
    for (0..len) |i| {
        const value = objects.getArrayElement(array, @intCast(i));
        if (value.tag != .object or value.data.obj_idx != child) continue;
        var j: u32 = @intCast(i);
        while (j+1 < len) : (j += 1) objects.setArrayElement(array, j, objects.getArrayElement(array, j+1));
        objects.arraySetLength(array, len-1);
        objects.getObject(child).dom_parent = objects.NULL_OBJ;
        objects.setProperty(child, values.internString("parentNode"), Value.NULL);
        syncDomChildren(parent);
        return true;
    }
    return false;
}
fn validDomPair(args: []const Value) bool {
    if (args.len >= 2 and args[0].tag == .object and args[1].tag == .object and objects.getObject(args[0].data.obj_idx).dom_node and objects.getObject(args[1].data.obj_idx).dom_node) return true;
    requestNativeThrow("DOM operation requires Node receivers"); return false;
}
fn domAppend(args: []const Value) Value {
    if (!validDomPair(args)) return Value.UNDEFINED;
    const parent = args[0].data.obj_idx;
    const child = args[1].data.obj_idx;
    var ancestor = parent;
    while (ancestor != objects.NULL_OBJ) {
        if (ancestor == child) { requestNativeThrow("Node cannot contain itself"); native_throw_name = "HierarchyRequestError"; return Value.UNDEFINED; }
        ancestor = objects.getObject(ancestor).dom_parent;
    }
    const previous = objects.getObject(child).dom_parent;
    const array = objects.getObject(parent).dom_children;
    if (!objects.arrayReserve(array, objects.arrayLength(array) + @as(u32, if (previous == parent) 0 else 1))) { requestRangeError("DOM child storage exceeded"); return Value.UNDEFINED; }
    if (previous != objects.NULL_OBJ) _ = detachDomChild(previous, child);
    objects.arrayPush(objects.getObject(parent).dom_children, args[1]);
    objects.getObject(child).dom_parent = parent;
    objects.setProperty(child, values.internString("parentNode"), args[0]);
    syncDomChildren(parent);
    if (objects.getObject(child).dom_iframe and domConnected(child)) {
        const load = objects.createFunction(N_DOM_FRAME_LOAD);
        _ = enqueueTask(&.{ Value.function(load), Value.number(0), args[1] }, false, false);
    }
    return args[1];
}
// Shared ordered insertion for insertBefore and replaceChild. Validate before
// detaching either node; resolve the reference again after same-parent moves.
fn domInsert(args: []const Value, replace: bool) Value {
    if (!validDomPair(args)) return Value.UNDEFINED;
    if (args.len < 3) { requestNativeThrow("DOM insertion requires a reference node"); return Value.UNDEFINED; }
    if (!replace and args[2].tag == .null_val) return domAppend(args[0..2]);
    const parent = args[0].data.obj_idx;
    const child = args[1].data.obj_idx;
    if (args[2].tag != .object or !objects.getObject(args[2].data.obj_idx).dom_node) {
        requestNativeThrow("DOM insertion requires a Node reference"); return Value.UNDEFINED;
    }
    const reference = args[2].data.obj_idx;
    if (objects.getObject(reference).dom_parent != parent) {
        requestNativeThrow("Node is not a child of this parent"); native_throw_name = "NotFoundError"; return Value.UNDEFINED;
    }
    if (child == reference) return args[1];
    var ancestor = parent;
    while (ancestor != objects.NULL_OBJ) {
        if (ancestor == child) { requestNativeThrow("Node cannot contain itself"); native_throw_name = "HierarchyRequestError"; return Value.UNDEFINED; }
        ancestor = objects.getObject(ancestor).dom_parent;
    }
    const array = objects.getObject(parent).dom_children;
    const previous = objects.getObject(child).dom_parent;
    const needed = objects.arrayLength(array) + @as(u32, if (!replace and previous != parent) 1 else 0);
    if (!objects.arrayReserve(array, needed)) { requestRangeError("DOM child storage exceeded"); return Value.UNDEFINED; }
    if (previous != objects.NULL_OBJ) _ = detachDomChild(previous, child);
    const len = objects.arrayLength(array);
    var at: u32 = 0;
    while (at < len) : (at += 1) {
        const value = objects.getArrayElement(array, at);
        if (value.tag == .object and value.data.obj_idx == reference) break;
    }
    if (replace) {
        objects.getObject(reference).dom_parent = objects.NULL_OBJ;
        objects.setProperty(reference, values.internString("parentNode"), Value.NULL);
    } else {
        var i = len;
        while (i > at) : (i -= 1) objects.setArrayElement(array, i, objects.getArrayElement(array, i-1));
    }
    objects.setArrayElement(array, at, args[1]);
    objects.getObject(child).dom_parent = parent;
    objects.setProperty(child, values.internString("parentNode"), args[0]);
    syncDomChildren(parent);
    if (objects.getObject(child).dom_iframe and domConnected(child)) {
        const load = objects.createFunction(N_DOM_FRAME_LOAD);
        _ = enqueueTask(&.{ Value.function(load), Value.number(0), args[1] }, false, false);
    }
    return if (replace) args[2] else args[1];
}
fn domConnected(node: u32) bool {
    var current = node;
    while (current != objects.NULL_OBJ) {
        if (current == dom_document_obj) return true;
        current = objects.getObject(current).dom_parent;
    }
    return false;
}
fn domFrameLoad(args: []const Value) Value {
    if (args.len == 0 or args[0].tag != .object or !objects.getObject(args[0].data.obj_idx).dom_iframe or !domConnected(args[0].data.obj_idx)) return Value.UNDEFINED;
    const event = makeEvent(&.{Value.string(values.internString("load"))});
    _ = eventDispatch(&.{ args[0], event });
    return Value.UNDEFINED;
}
fn domRemove(args: []const Value) Value {
    if (!validDomPair(args)) return Value.UNDEFINED;
    if (objects.getObject(args[1].data.obj_idx).dom_parent != args[0].data.obj_idx or !detachDomChild(args[0].data.obj_idx, args[1].data.obj_idx)) {
        requestNativeThrow("Node is not a child of this parent"); native_throw_name = "NotFoundError"; return Value.UNDEFINED;
    }
    return args[1];
}
fn makeEvent(args: []const Value) Value {
    const event = objects.createObject();
    const kind = if (args.len > 0) stringCtor(args[0..1]) else Value.string(values.internString(""));
    if (callbackAborted()) return Value.UNDEFINED;
    objects.setProperty(event, values.internString("type"), kind);
    const options = if (args.len > 1 and args[1].tag == .object) args[1] else Value.UNDEFINED;
    for ([_][]const u8{ "bubbles", "cancelable", "composed" }) |key| {
        const value = if (options.tag == .object) objects.getProperty(options.data.obj_idx, values.internString(key)).isTruthy() else false;
        objects.setProperty(event, values.internString(key), boolVal(value));
    }
    objects.setProperty(event, values.internString("defaultPrevented"), Value.FALSE);
    objects.setProperty(event, values.internString("isTrusted"), Value.FALSE);
    objects.setProperty(event, values.internString("target"), Value.NULL);
    objects.setProperty(event, values.internString("currentTarget"), Value.NULL);
    objects.setProperty(event, values.internString("eventPhase"), Value.number(0));
    installNativeMethod(event, "preventDefault", N_EVENT_PREVENT);
    installNativeMethod(event, "stopImmediatePropagation", N_EVENT_STOP_IMMEDIATE);
    installNativeMethod(event, "stopPropagation", N_DOM_NOOP);
    return Value.object(event);
}
fn eventPrevent(args: []const Value) Value {
    if (args.len > 0 and args[0].tag == .object and objects.getProperty(args[0].data.obj_idx, values.internString("cancelable")).isTruthy())
        objects.setProperty(args[0].data.obj_idx, values.internString("defaultPrevented"), Value.TRUE);
    return Value.UNDEFINED;
}
fn eventStopImmediate(args: []const Value) Value {
    if (args.len > 0 and args[0].tag == .object) events.stopImmediate(args[0].data.obj_idx);
    return Value.UNDEFINED;
}
fn eventDispatch(args: []const Value) Value {
    if (args.len < 2 or args[0].tag != .object or args[1].tag != .object) { requestNativeThrow("dispatchEvent requires an EventTarget and event"); return Value.UNDEFINED; }
    const event = args[1].data.obj_idx;
    const kind = objects.getProperty(event, values.internString("type"));
    if (kind.tag != .string or values.getString(kind.data.str_idx).len == 0 or events.isDispatching(event)) { requestNativeThrow("Event is uninitialized or already dispatching"); return Value.UNDEFINED; }
    if (!events.hasCapacity()) { requestRangeError("Event dispatch depth exceeded"); return Value.UNDEFINED; }
    const invoke = invoke_callback orelse return Value.TRUE;
    const aborted = callback_aborted orelse return Value.TRUE;
    return boolVal(events.dispatch(args[0].data.obj_idx, event, invoke, aborted));
}
fn domClick(args: []const Value) Value {
    if (args.len == 0 or args[0].tag != .object) { requestNativeThrow("click requires an element"); return Value.UNDEFINED; }
    const target = args[0].data.obj_idx;
    if (objects.getProperty(target, values.internString("disabled")).isTruthy() or events.isClicking(target)) return Value.UNDEFINED;
    if (!events.enterClick(target)) { requestRangeError("Click dispatch depth exceeded"); return Value.UNDEFINED; }
    defer events.leaveClick();
    const event = makeEvent(&.{Value.string(values.internString("click"))});
    objects.setProperty(event.data.obj_idx, values.internString("bubbles"), Value.TRUE);
    objects.setProperty(event.data.obj_idx, values.internString("cancelable"), Value.TRUE);
    _ = eventDispatch(&.{ args[0], event });
    return Value.UNDEFINED;
}

fn makeOrientationEvent(args: []const Value) Value {
    const event = objects.createObject();
    objects.setProperty(event, values.internString("type"), if (args.len > 0) args[0] else Value.string(values.internString("")));
    for ([_][]const u8{ "alpha", "beta", "gamma" }) |name| objects.setProperty(event, values.internString(name), Value.NULL);
    for ([_][]const u8{ "absolute", "bubbles", "cancelable", "defaultPrevented", "isTrusted" }) |name| objects.setProperty(event, values.internString(name), Value.FALSE);
    installNativeMethod(event, "preventDefault", N_DOM_NOOP);
    installNativeMethod(event, "stopPropagation", N_DOM_NOOP);
    return Value.object(event);
}

fn makeDomRect() Value {
    const rect = objects.createObject();
    for ([_][]const u8{ "x", "y", "width", "height", "top", "right", "bottom", "left" }) |name|
        objects.setProperty(rect, values.internString(name), Value.number(0));
    return Value.object(rect);
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
        requestNativeThrow("Function.prototype.toString requires that 'this' be a Function");
        return Value.UNDEFINED;
    }
    const fid = objects.closureFuncId(args[0].data.obj_idx);
    if (fid != 0xFFFF) {
        const src = compiler.funcSourceText(fid);
        if (src.len > 0 and (src[0] == 'f' or src[0] == '(' or src[0] == 'a')) {
            return Value.string(values.internString(src));
        }
    }
    return Value.string(nativeFunctionSource(args[0]));
}

pub fn nativeFunctionSource(value: Value) u32 {
    const stored = objects.getObject(value.data.func_idx).native_name;
    const name = if (stored != objects.NULL_OBJ) Value.string(stored) else objects.getProperty(value.data.func_idx, values.internString("name"));
    const text = if (name.tag == .string) values.getString(name.data.str_idx) else "";
    var buf: [256]u8 = undefined;
    const prefix = "function ";
    const suffix = "() { [native code] }";
    const count = @min(text.len, buf.len - prefix.len - suffix.len);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..count], text[0..count]);
    @memcpy(buf[prefix.len + count..][0..suffix.len], suffix);
    return values.internString(buf[0..prefix.len + count + suffix.len]);
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
    // WebIDL converts the first input, including objects/functions, before
    // invoking the policy. Extra callback arguments must not replace it.
    return stringCtor(&.{if (args.len > 1) args[1] else Value.UNDEFINED});
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

var fromcharcode_buf: [65536]u8 = undefined;
fn strFromCharCode(args: []const Value) Value {
    var len: usize = 0;
    for (args) |a| {
        const code = toU16(a.toNumber());
        if (callbackAborted()) return Value.UNDEFINED;
        const written = values.encodeCodeUnit(code, fromcharcode_buf[len..]);
        if (written == 0) { requestRangeError("String.fromCharCode exceeds fixed capacity"); return Value.UNDEFINED; }
        len += written;
    }
    return Value.string(values.internString(fromcharcode_buf[0..len]));
}

fn strCharAt(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const index = if (args.len > 1) args[1].toNumber() else 0;
    if (callbackAborted()) return Value.UNDEFINED;
    if (index < 0 or index >= @as(f64, @floatFromInt(values.getStringUnitLength(args[0].data.str_idx)))) return Value.string(values.internString(""));
    return Value.string(values.getStringUnit(args[0].data.str_idx, safeIndex(index)));
}

pub var dbg_source_n: usize = 0;
pub var dbg_source_strings: [256]u32 = undefined;
fn strCharCodeAt(args: []const Value) Value {
    if (args.len == 0) return Value.number(dateNaN());
    const idx = args[0].data.str_idx;
    const index = if (args.len > 1) args[1].toNumber() else 0;
    if (callbackAborted()) return Value.UNDEFINED;
    if (index < 0 or index >= @as(f64, @floatFromInt(values.getStringUnitLength(idx)))) return Value.number(dateNaN());
    if (safeIndex(index) == 0 and values.getStringLen(idx) >= 8 and dbg_source_n < 256) { dbg_source_strings[dbg_source_n] = idx; dbg_source_n += 1; }
    return if (values.getStringCodeUnit(idx, safeIndex(index))) |unit| Value.number(@floatFromInt(unit)) else Value.number(dateNaN());
}

fn strIndexOf(args: []const Value) Value {
    if (args.len == 0) return Value.number(-1);
    const idx = args[0].data.str_idx;
    const haystack = values.getString(idx);
    const needle_value = stringCtor(&.{if (args.len > 1) args[1] else Value.UNDEFINED});
    if (callbackAborted()) return Value.UNDEFINED;
    const needle = values.getString(needle_value.data.str_idx);
    const count = values.getStringUnitLength(idx);
    const position = if (args.len > 2) toI64(args[2].toNumber()) else 0;
    if (callbackAborted()) return Value.UNDEFINED;
    const start: usize = @intCast(@min(@max(position, 0), @as(i64, @intCast(count))));
    if (needle.len == 0) return Value.number(@floatFromInt(start));
    for (start..count) |unit| {
        const byte = values.stringUnitByteOffset(idx, unit);
        if (needle.len <= haystack.len-byte and eql(haystack[byte..][0..needle.len], needle)) return Value.number(@floatFromInt(unit));
    }
    return Value.number(-1);
}
fn strSubstring(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const idx = args[0].data.str_idx;
    const count: i64 = @intCast(values.getStringUnitLength(idx));
    const from = if (args.len > 1) toI64(args[1].toNumber()) else 0;
    if (callbackAborted()) return Value.UNDEFINED;
    const to = if (args.len > 2 and args[2].tag != .undefined) toI64(args[2].toNumber()) else count;
    if (callbackAborted()) return Value.UNDEFINED;
    const start = @min(@max(from, 0), count);
    const end = @min(@max(to, 0), count);
    return Value.string(values.sliceStringUnits(idx, @intCast(@min(start, end)), @intCast(@max(start, end))));
}

fn strSlice(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const idx = args[0].data.str_idx;
    const len: i64 = @intCast(values.getStringUnitLength(idx));
    var start: i64 = if (args.len > 1) toI64(args[1].toNumber()) else 0;
    if (callbackAborted()) return Value.UNDEFINED;
    var end: i64 = if (args.len > 2 and args[2].tag != .undefined) toI64(args[2].toNumber()) else len;
    if (callbackAborted()) return Value.UNDEFINED;
    start = if (start < 0) @max(len + start, 0) else @min(start, len);
    end = if (end < 0) @max(len + end, 0) else @min(end, len);
    return Value.string(values.sliceStringUnits(idx, @intCast(start), @intCast(@max(start, end))));
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
            for (0..@min(values.getStringUnitLength(text_val.data.str_idx), limit)) |i| objects.arrayPush(arr, Value.string(values.getStringUnit(text_val.data.str_idx, i)));
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
            if (callbackAborted()) return Value.UNDEFINED;
            const literal = values.getString(stringCtor(&.{result}).data.str_idx);
            if (callbackAborted()) return Value.UNDEFINED;
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
    const number = args[1].toNumber();
    if (number < 0 or number > @as(f64, @floatFromInt(str_concat_buf.len))) { requestNativeThrow("Invalid string repeat count"); return Value.UNDEFINED; }
    const count: usize = safeIndex(number);
    if (str.len == 0) return Value.string(values.internString(""));
    if (count > str_concat_buf.len / str.len) { requestNativeThrow("String repeat exceeds fixed capacity"); return Value.UNDEFINED; }
    const buf = &str_concat_buf;
    var len: usize = 0;
    for (0..count) |_| {
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
        if (native_throw or callbackAborted()) return Value.UNDEFINED;
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
            const comparison: f64 = if (args.len > 1 and args[1].tag == .function and invoke_callback != null)
                invoke_callback.?(args[1], Value.UNDEFINED, &.{prev, cur}).toNumber()
            else @floatFromInt(defaultCompare(prev, cur));
            if (callbackAborted()) return Value.UNDEFINED;
            if (comparison != comparison or comparison <= 0) break;
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
    const value = numberValue(args);
    if (native_throw) return Value.UNDEFINED;
    const n = value.data.number;
    var radix: u32 = 10;
    if (args.len >= 2 and args[1].tag != .undefined) {
        const r = args[1].toNumber();
        const integer = if (r != r) 0 else @trunc(r);
        if (integer < 2 or integer > 36) {
            requestRangeError("toString() radix argument must be between 2 and 36");
            return Value.UNDEFINED;
        }
        radix = @intFromFloat(integer);
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
// Shared fixed arena with a separate reservation for each active join. Guest
// getters and ToString methods may invoke join again without overwriting an
// outer prefix. Results are interned before the reservation is released.
var join_buf: [512 * 1024]u8 = undefined;
var join_used: usize = 0;
var join_receivers: [64]u32 = undefined;
var join_depth: usize = 0;
fn arrToString(args: []const Value) Value {
    if (args.len == 0 or args[0].tag == .null_val or args[0].tag == .undefined) {
        requestNativeThrow("Array.toString requires a non-null receiver"); return Value.UNDEFINED;
    }
    const receiver = objectCtor(&.{args[0]});
    const join = descriptorField(receiver, values.internString("join"));
    if (native_throw or callbackAborted()) return Value.UNDEFINED;
    if (join.tag == .function) {
        if (invoke_callback) |invoke| return invoke(join, receiver, &.{});
        requestNativeThrow("Array.toString callback requires the interpreter"); return Value.UNDEFINED;
    }
    return callNative(N_OBJ_TOSTRING, &.{receiver}, 1);
}
fn arrJoin(args: []const Value) Value {
    if (args.len == 0 or args[0].tag == .undefined or args[0].tag == .null_val) {
        requestNativeThrow("Array.join requires a non-null receiver"); return Value.UNDEFINED;
    }
    const receiver = args[0];
    const object = objectValue(receiver);
    const string = receiver.tag == .string;
    const count: f64 = if (string) @floatFromInt(values.getStringUnitLength(receiver.data.str_idx))
        else if (object and objects.objTypeOf(receiver.data.obj_idx) == .array) @floatFromInt(objects.arrayLength(receiver.data.obj_idx))
        else if (object) descriptorField(receiver, values.internString("length")).toNumber() else 0;
    if (native_throw or callbackAborted()) return Value.UNDEFINED;
    const length: usize = if (count != count or count <= 0) 0 else blk: {
        if (count > objects.MAX_ARRAY_ELEMENTS) { requestRangeError("Array.join length exceeds fixed capacity"); return Value.UNDEFINED; }
        break :blk @intFromFloat(@floor(count));
    };
    const separator_value = if (args.len < 2 or args[1].tag == .undefined) Value.string(values.internString(",")) else stringCtor(&.{args[1]});
    if (native_throw or callbackAborted()) return Value.UNDEFINED;
    const separator = values.getString(separator_value.data.str_idx);
    if (object) for (join_receivers[0..join_depth]) |active| {
        if (active == receiver.data.obj_idx) return Value.string(values.internString(""));
    };
    if (join_depth == join_receivers.len) { requestRangeError("Array.join nesting exceeds fixed capacity"); return Value.UNDEFINED; }
    const start = join_used;
    join_receivers[join_depth] = if (object) receiver.data.obj_idx else objects.NULL_OBJ;
    join_depth += 1;
    defer { join_used = start; join_depth -= 1; }
    for (0..length) |i| {
        if (i > 0 and !joinAppend(separator)) return Value.UNDEFINED;
        const element = if (string) Value.string(values.getStringUnit(receiver.data.str_idx, i))
            else if (!objects.getObject(receiver.data.obj_idx).is_arguments and objects.hasArrayElement(receiver.data.obj_idx, @intCast(i))) objects.getArrayElement(receiver.data.obj_idx, @intCast(i))
            else blk: {
                var key_buf: [16]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch unreachable;
                break :blk descriptorField(receiver, values.internString(key));
            };
        if (native_throw or callbackAborted()) return Value.UNDEFINED;
        if (element.tag == .undefined or element.tag == .null_val) continue;
        const text = stringCtor(&.{element});
        if (native_throw or callbackAborted()) return Value.UNDEFINED;
        if (!joinAppend(values.getString(text.data.str_idx))) return Value.UNDEFINED;
    }
    return Value.string(values.internString(join_buf[start..join_used]));
}
fn joinAppend(text: []const u8) bool {
    if (text.len > join_buf.len - join_used) { requestRangeError("Array.join exceeds fixed string capacity"); return false; }
    @memcpy(join_buf[join_used..][0..text.len], text);
    join_used += text.len;
    return true;
}

/// Minimal integer/float formatting for join (BotGuard values are integers).
fn numberToText(n: f64, buf: *[32]u8) usize { return values.numberToString(n, buf); }

fn arrIncludes(args: []const Value) Value {
    if (args.len < 2) return Value.FALSE;
    if (args[0].tag != .object and args[0].tag != .array) return Value.FALSE;
    const obj_idx: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(obj_idx);
    var i = arraySearchStart(args, len);
    while (i < len) : (i += 1) {
        const elem = objects.getArrayElement(obj_idx, i);
        if (arraySearchEqual(elem, args[1], true)) return Value.TRUE;
    }
    return Value.FALSE;
}

fn arrIndexOf(args: []const Value) Value {
    if (args.len < 2) return Value.number(-1);
    if (args[0].tag != .object and args[0].tag != .array) return Value.number(-1);
    const obj_idx: u32 = args[0].data.obj_idx;
    const len = objects.arrayLength(obj_idx);
    var i = arraySearchStart(args, len);
    while (i < len) : (i += 1) {
        if (!objects.hasArrayElement(obj_idx, i)) continue;
        const elem = objects.getArrayElement(obj_idx, i);
        if (arraySearchEqual(elem, args[1], false)) return Value.number(@floatFromInt(i));
    }
    return Value.number(-1);
}

// Compare the active union member. Reading data.number for an interned string
// also reads unrelated upper storage bytes and can corrupt character lookup.
fn arraySearchEqual(a: Value, b: Value, same_value_zero: bool) bool {
    if (a.tag != b.tag) return false;
    return switch (a.tag) {
        .undefined, .null_val => true,
        .boolean => a.data.boolean == b.data.boolean,
        .number => a.data.number == b.data.number or (same_value_zero and a.data.number != a.data.number and b.data.number != b.data.number),
        .string => a.data.str_idx == b.data.str_idx,
        .object, .array, .function, .symbol => a.data.obj_idx == b.data.obj_idx,
    };
}

fn arraySearchStart(args: []const Value, len: u32) u32 {
    if (args.len < 3) return 0;
    const n = args[2].toNumber();
    if (n != n or n == 0) return 0;
    const flen: f64 = @floatFromInt(len);
    if (n >= flen) return len;
    if (n <= -flen) return 0;
    const integer = if (n < 0) @ceil(n) else @floor(n);
    return @intFromFloat(if (integer < 0) flen + integer else integer);
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
        const length = args[0].data.number;
        if (length != length or length < 0 or length > 4294967295 or @trunc(length) != length) {
            requestRangeError("Invalid array length");
            return Value.UNDEFINED;
        }
        const n: u32 = @intFromFloat(length);
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

pub var dbg_window_names_on: bool = false;
pub var dbg_window_names_n: usize = 0;
pub var dbg_window_names: [4096]u32 = undefined;
pub var dbg_own_names_on: bool = false;
pub var dbg_own_names_n: usize = 0;
pub var dbg_own_names: [256]u32 = undefined;
fn recordOwnNames(result: u32) void {
    if (!dbg_own_names_on or dbg_own_names_n == dbg_own_names.len) return;
    dbg_own_names[dbg_own_names_n] = result;
    dbg_own_names_n += 1;
}
fn objOwnNames(args: []const Value) Value {
    if (args.len < 2 or args[1].tag == .null_val or args[1].tag == .undefined) {
        requestNativeThrow("Cannot convert undefined or null to object");
        return Value.UNDEFINED;
    }
    var keys: [4096]u32 = undefined;
    const input = args[1];
    const count = if (input.tag == .object or input.tag == .array or input.tag == .function) objects.enumerateOwnKeys(input.data.obj_idx, &keys, false) else 0;
    if (input.tag == .object and objects.getObject(input.data.obj_idx).dom_window) {
        const result = objects.createArray(0);
        for (browser_metadata.window_names) |name| {
            const key = values.internString(name);
            if (objects.hasOwnProperty(input.data.obj_idx, key)) objects.arrayPush(result, Value.string(key));
        }
        for (keys[0..count]) |key| {
            var found = false;
            for (browser_metadata.window_names) |name| if (eql(values.getString(key), name)) { found = true; break; };
            if (!found) objects.arrayPush(result, Value.string(key));
        }
        if (dbg_window_names_on and dbg_window_names_n == 0) {
            dbg_window_names_n = @min(objects.arrayLength(result), dbg_window_names.len);
            for (0..dbg_window_names_n) |i| dbg_window_names[i] = objects.getArrayElement(result, @intCast(i)).data.str_idx;
        }
        recordOwnNames(result);
        return Value.object(result);
    }
    const result = objects.createArray(@intCast(count));
    for (keys[0..count], 0..) |key, i| objects.setArrayElement(result, @intCast(i), Value.string(key));
    recordOwnNames(result);
    return Value.object(result);
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
var atob_text: [131072]u8 = undefined;
fn nAtob(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(stringCtor(args[0..1]).data.str_idx);
    if (callbackAborted()) return Value.UNDEFINED;
    const len = base64Decode(str, &atob_buf);
    if (native_throw) return Value.UNDEFINED;
    var used: usize = 0;
    for (atob_buf[0..len]) |byte| used += values.encodeCodeUnit(byte, atob_text[used..]);
    return Value.string(values.internString(atob_text[0..used]));
}

var btoa_buf: [131072]u8 = undefined;
var btoa_bytes: [65536]u8 = undefined;
fn nBtoa(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const idx = stringCtor(args[0..1]).data.str_idx;
    if (callbackAborted()) return Value.UNDEFINED;
    const count = values.getStringUnitLength(idx);
    if (count > btoa_bytes.len) { requestRangeError("btoa exceeds fixed capacity"); return Value.UNDEFINED; }
    for (0..count) |i| {
        const unit = values.getStringCodeUnit(idx, i).?;
        if (unit > 255) { requestNativeThrow("The string to be encoded contains characters outside of the Latin1 range"); native_throw_name = "InvalidCharacterError"; return Value.UNDEFINED; }
        btoa_bytes[i] = @intCast(unit);
    }
    const len = base64Encode(btoa_bytes[0..count], &btoa_buf);
    return Value.string(values.internString(btoa_buf[0..len]));
}

fn dateNow() Value {
    var ft: FileTime = undefined;
    GetSystemTimeAsFileTime(&ft);
    const ticks = (@as(u64, ft.high) << 32) | ft.low;
    return Value.number(@floatFromInt(ticks / 10000 - 11644473600000));
}

fn dateNaN() f64 { return @bitCast(@as(u64, 0x7FF8000000000000)); }

fn dateParts(ms: f64, utc: *SystemTime, local: *SystemTime) bool {
    if (ms != ms or ms < -11644473600000 or ms > 9e14) return false;
    const ticks: u64 = @intFromFloat((ms + 11644473600000) * 10000);
    const ft = FileTime{ .low = @truncate(ticks), .high = @truncate(ticks >> 32) };
    return FileTimeToSystemTime(&ft, utc) != 0 and SystemTimeToTzSpecificLocalTime(null, utc, local) != 0;
}

fn dateOffset(utc: SystemTime, local: SystemTime) i64 {
    const day_delta = dateDays(utc.year, utc.month, utc.day) - dateDays(local.year, local.month, local.day);
    return day_delta * 1440 + @as(i64, utc.hour) * 60 + utc.minute - @as(i64, local.hour) * 60 - local.minute;
}

fn datePad(buf: []u8, cursor: *usize, value: u32, width: usize) void {
    var n = value;
    var i = width;
    while (i > 0) { i -= 1; buf[cursor.* + i] = @intCast('0' + n % 10); n /= 10; }
    cursor.* += width;
}

/// Local Date string from the OS calendar and zone, with no locale/runtime
/// dependency. Date() and Date.prototype.toString share the same conversion.
fn dateString(value: Value) Value {
    if (value.tag != .object or objects.objTypeOf(value.data.obj_idx) != .date) {
        requestNativeThrow("Method Date.prototype.toString called on incompatible receiver");
        return Value.UNDEFINED;
    }
    return dateStringFromTime(objects.getObject(value.data.obj_idx).number_value);
}

fn dateStringFromTime(ms: f64) Value {
    var utc: SystemTime = undefined;
    var local: SystemTime = undefined;
    if (!dateParts(ms, &utc, &local)) return Value.string(values.internString("Invalid Date"));
    var buf: [192]u8 = undefined;
    var n: usize = 0;
    const weekdays = "SunMonTueWedThuFriSat";
    const months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    @memcpy(buf[n..][0..3], weekdays[@as(usize, local.weekday) * 3..][0..3]); n += 3; buf[n] = ' '; n += 1;
    @memcpy(buf[n..][0..3], months[@as(usize, local.month - 1) * 3..][0..3]); n += 3; buf[n] = ' '; n += 1;
    datePad(&buf, &n, local.day, 2); buf[n] = ' '; n += 1;
    datePad(&buf, &n, local.year, 4); buf[n] = ' '; n += 1;
    datePad(&buf, &n, local.hour, 2); buf[n] = ':'; n += 1;
    datePad(&buf, &n, local.minute, 2); buf[n] = ':'; n += 1;
    datePad(&buf, &n, local.second, 2);
    @memcpy(buf[n..][0..4], " GMT"); n += 4;
    const offset = dateOffset(utc, local);
    buf[n] = if (offset <= 0) '+' else '-'; n += 1;
    const magnitude: u32 = @intCast(if (offset < 0) -offset else offset);
    datePad(&buf, &n, magnitude / 60, 2); datePad(&buf, &n, magnitude % 60, 2);
    var zone: TimeZoneInformation = undefined;
    if (GetTimeZoneInformation(&zone) != 0xFFFFFFFF) {
        const zone_name = if (offset == @as(i64, zone.bias) + zone.daylight_bias and zone.daylight_date.month != 0) zone.daylight_name else zone.standard_name;
        if (zone_name[0] != 0) {
            buf[n] = ' '; buf[n+1] = '('; n += 2;
            for (zone_name) |c| {
                if (c == 0) break;
                if (c < 128) { buf[n] = @intCast(c); n += 1; }
                else if (c < 2048) { buf[n] = @intCast(192 | (c >> 6)); buf[n+1] = @intCast(128 | (c & 63)); n += 2; }
                else { buf[n] = @intCast(224 | (c >> 12)); buf[n+1] = @intCast(128 | ((c >> 6) & 63)); buf[n+2] = @intCast(128 | (c & 63)); n += 3; }
            }
            buf[n] = ')'; n += 1;
        }
    }
    return Value.string(values.internString(buf[0..n]));
}

fn dateLocalPart(args: []const Value, func_id: u16) Value {
    if (args.len == 0 or args[0].tag != .object or objects.objTypeOf(args[0].data.obj_idx) != .date) return Value.number(dateNaN());
    const ms = objects.getObject(args[0].data.obj_idx).number_value;
    var utc: SystemTime = undefined;
    var local: SystemTime = undefined;
    if (!dateParts(ms, &utc, &local)) return Value.number(dateNaN());
    if (func_id == N_DATE_HOURS) return Value.number(@floatFromInt(local.hour));
    if (func_id == N_DATE_MINUTES) return Value.number(@floatFromInt(local.minute));
    return Value.number(@floatFromInt(dateOffset(utc, local)));
}

fn dateDigits(text: []const u8, start: usize, count: usize) ?i64 {
    if (start + count > text.len) return null;
    var n: i64 = 0;
    for (text[start..start + count]) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + c - '0';
    }
    return n;
}

// days_from_civil, the inverse of @zpm/core/timefmt's calendar conversion.
fn dateDays(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    return era * 146097 + yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy - 719468;
}

/// ISO date strings with UTC/explicit offsets. Current player transforms use
/// these constants as exact arithmetic operands, including dates before 1970.
fn parseDateIso(text: []const u8) f64 {
    if (text.len < 10 or text[4] != '-' or text[7] != '-') return dateNaN();
    const year = dateDigits(text, 0, 4) orelse return dateNaN();
    const month = dateDigits(text, 5, 2) orelse return dateNaN();
    const day = dateDigits(text, 8, 2) orelse return dateNaN();
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const month_days = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month < 1 or month > 12 or day < 1 or day > month_days[@intCast(month - 1)]) return dateNaN();
    var millis = dateDays(year, month, day) * 86400000;
    if (text.len == 10) return @floatFromInt(millis);
    if (text.len < 16 or text[10] != 'T' or text[13] != ':') return dateNaN();
    const hour = dateDigits(text, 11, 2) orelse return dateNaN();
    const minute = dateDigits(text, 14, 2) orelse return dateNaN();
    var second: i64 = 0;
    var fraction: i64 = 0;
    var p: usize = 16;
    if (p < text.len and text[p] == ':') {
        second = dateDigits(text, p + 1, 2) orelse return dateNaN();
        p += 3;
        if (p < text.len and text[p] == '.') {
            p += 1;
            const start = p;
            while (p < text.len and text[p] >= '0' and text[p] <= '9') : (p += 1) {}
            const digits = p - start;
            if (digits == 0 or digits > 3) return dateNaN();
            fraction = dateDigits(text, start, digits) orelse return dateNaN();
            if (digits == 1) fraction *= 100 else if (digits == 2) fraction *= 10;
        }
    }
    if (hour > 24 or minute > 59 or second > 59 or (hour == 24 and (minute != 0 or second != 0 or fraction != 0))) return dateNaN();
    millis += ((hour * 60 + minute) * 60 + second) * 1000 + fraction;
    if (p < text.len and text[p] == 'Z' and p + 1 == text.len) return @floatFromInt(millis);
    if (p + 6 != text.len or (text[p] != '+' and text[p] != '-') or text[p + 3] != ':') return dateNaN();
    const zone_hour = dateDigits(text, p + 1, 2) orelse return dateNaN();
    const zone_minute = dateDigits(text, p + 4, 2) orelse return dateNaN();
    if (zone_hour > 23 or zone_minute > 59) return dateNaN();
    const offset = (zone_hour * 60 + zone_minute) * 60000;
    millis += if (text[p] == '+') -offset else offset;
    return @floatFromInt(millis);
}

pub fn constructDate(args: []const Value) Value {
    const timestamp = if (args.len == 0) dateNow().data.number else if (args[0].tag == .string) parseDateIso(values.getString(args[0].data.str_idx)) else args[0].toNumber();
    const clipped = if (timestamp != timestamp or timestamp < -8.64e15 or timestamp > 8.64e15) dateNaN() else @trunc(timestamp);
    return Value.object(objects.createDate(clipped, date_proto));
}

// Milliseconds since environment initialization, measured by the monotonic
// Windows performance counter. The deterministic clock is an explicit debug
// option; the small increment is also a fallback when the counter is unavailable.
pub var dbg_deterministic_clock: bool = false;
var perf_now_ms: f64 = 0;
var perf_counter_start: i64 = 0;
var perf_counter_frequency: i64 = 0;
pub var performance_time_origin: f64 = 0;
fn perfNow() Value {
    if (!dbg_deterministic_clock and perf_counter_frequency > 0) {
        var now: i64 = 0;
        if (QueryPerformanceCounter(&now) != 0) {
            const elapsed = @as(f64, @floatFromInt(now - perf_counter_start)) * 1000 / @as(f64, @floatFromInt(perf_counter_frequency));
            perf_now_ms = @max(perf_now_ms, elapsed);
            return Value.number(perf_now_ms);
        }
    }
    const v = perf_now_ms;
    perf_now_ms += 0.005; // 5µs per call — monotonic, negligible elapsed
    return Value.number(v);
}
pub fn resetPerfNow() void {
    perf_now_ms = 0;
    performance_time_origin = dateNow().toNumber();
    perf_counter_frequency = 0;
    _ = QueryPerformanceFrequency(&perf_counter_frequency);
    _ = QueryPerformanceCounter(&perf_counter_start);
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
    // Method calls prepend the Crypto receiver. Fill the actual integer view,
    // preserving its identity, offset, aliasing and the full element width.
    if (args.len == 0) { requestNativeThrow("getRandomValues requires an integer typed array"); return Value.UNDEFINED; }
    const view = args[args.len - 1];
    if (view.tag != .object or objects.objTypeOf(view.data.obj_idx) != .typed_array) {
        requestNativeThrow("getRandomValues requires an integer typed array");
        return Value.UNDEFINED;
    }
    const object = objects.getObject(view.data.obj_idx);
    if (object.byte_length > 65536) { requestNativeThrow("getRandomValues exceeds 65536 bytes"); native_throw_name = "QuotaExceededError"; return Value.UNDEFINED; }
    const bytes = objects.getBufferBytes(object.buffer_id)[object.byte_offset..][0..object.byte_length];
    if (bytes.len > 0 and BCryptGenRandom(null, bytes.ptr, @intCast(bytes.len), 2) < 0) {
        requestNativeThrow("System random source failed");
        return Value.UNDEFINED;
    }
    return view;
}

fn createTypedArrayN(args: []const Value, elem_size: u8) Value {
    var len: u32 = 0;
    if (args.len > 0 and args[0].tag == .number) {
        len = safeLen(args[0].toNumber());
    } else if (args.len > 0 and (args[0].tag == .object or args[0].tag == .array)) {
        // new Uint8Array(existingArray) — copy its elements.
        const src: u32 = args[0].data.obj_idx;
        if (objects.objTypeOf(src) == .array_buffer) {
            const size = objects.getObject(src).byte_length;
            const offset = if (args.len > 1) safeLen(args[1].toNumber()) else 0;
            if (offset > size or offset % elem_size != 0 or (args.len < 3 and (size - offset) % elem_size != 0)) {
                requestRangeError("Invalid typed array view");
                return Value.UNDEFINED;
            }
            const count = if (args.len > 2) safeLen(args[2].toNumber()) else (size - offset) / elem_size;
            const view = objects.createTypedArray(src, offset, count, elem_size);
            if (view == objects.NULL_OBJ) {
                requestRangeError("Typed array view exceeds buffer");
                return Value.UNDEFINED;
            }
            return Value.object(view);
        }
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
        if (o + 4 > out.len) break;
        const b0 = data[i];
        const b1 = data[i + 1];
        const b2 = data[i + 2];
        out[o] = B64_TABLE[b0 >> 2]; o += 1;
        out[o] = B64_TABLE[((b0 & 3) << 4) | (b1 >> 4)]; o += 1;
        out[o] = B64_TABLE[((b1 & 0xF) << 2) | (b2 >> 6)]; o += 1;
        out[o] = B64_TABLE[b2 & 0x3F]; o += 1;
    }
    if (i < data.len and o + 4 <= out.len) {
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
    var symbols: usize = 0; var padding: usize = 0;
    for (data) |ch| {
        if (ch == 9 or ch == 10 or ch == 12 or ch == 13 or ch == 32) continue;
        if (ch == '=') { padding += 1; continue; }
        if (padding > 0 or !((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '+' or ch == '/')) return invalidBase64();
        symbols += 1;
    }
    const remainder = symbols % 4;
    if (remainder == 1 or padding > 2 or (padding > 0 and ((symbols + padding) % 4 != 0 or (padding == 1 and remainder != 3) or (padding == 2 and remainder != 2)))) return invalidBase64();
    const needed = symbols / 4 * 3 + (if (remainder == 2) @as(usize, 1) else if (remainder == 3) @as(usize, 2) else @as(usize, 0));
    if (needed > out.len) { requestRangeError("atob exceeds fixed binary capacity"); return 0; }
    var carry: u32 = 0; var bits: u5 = 0; var used: usize = 0;
    for (data) |ch| {
        if (ch == '=' or ch == 9 or ch == 10 or ch == 12 or ch == 13 or ch == 32) continue;
        carry = (carry << 6) | b64Val(ch); bits += 6;
        if (bits >= 8) { bits -= 8; out[used] = @truncate(carry >> bits); used += 1; }
        carry &= (@as(u32, 1) << bits) - 1;
    }
    return used;
}
fn invalidBase64() usize {
    requestNativeThrow("The string to be decoded is not correctly encoded");
    native_throw_name = "InvalidCharacterError";
    return 0;
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

pub fn installNativeMethod(obj: u32, name: []const u8, func_id: u16) void {
    const func_obj = objects.createFunction(func_id);
    setNativeFunctionMetadata(func_obj, name, nativeArity(func_id));
    objects.setProperty(obj, values.internString(name), Value.function(func_obj));
    objects.setEnumerable(obj, values.internString(name), false);
}

fn installNativeGlobal(global: u32, name: []const u8, func_id: u16) void {
    const func_obj = objects.createFunction(func_id);
    setNativeFunctionMetadata(func_obj, name, nativeArity(func_id));
    objects.setProperty(global, values.internString(name), Value.function(func_obj));
}
pub fn setNativeFunctionMetadata(function: u32, name: []const u8, arity: u8) void {
    objects.getObject(function).native_name = values.internString(name);
    for ([_][]const u8{"length", "name"}) |key_text| {
        const key = values.internString(key_text);
        objects.defineLiteralProperty(function, key, if (eql(key_text, "length")) Value.number(@floatFromInt(arity)) else Value.string(values.internString(name)), 0);
        objects.setEnumerable(function, key, false);
        objects.setWritable(function, key, false);
    }
}
fn nativeArity(id: u16) u8 {
    return switch (id) {
        N_DATE_CTOR => 7,
        N_OBJ_DEFINE_PROP, N_JSON_STRINGIFY, N_UINT8_ARRAY, N_UINT16_ARRAY, N_UINT32_ARRAY, N_INT8_ARRAY, N_DATA_VIEW => 3,
        N_MATH_MIN, N_MATH_MAX, N_MATH_POW, N_MATH_IMUL, N_MATH_ATAN2, N_PARSE_INT,
        N_STR_SLICE, N_STR_SUBSTRING, N_STR_SPLIT, N_STR_REPLACE, N_JSON_PARSE,
        N_ARR_SPLICE, N_ARR_SLICE, N_OBJ_ASSIGN, N_OBJ_CREATE, N_OBJ_GET_OWN_DESC,
        N_REGEXP_CTOR, N_PROXY_CONSTRUCTOR, N_FN_APPLY, N_EVENT_ADD, N_EVENT_REMOVE => 2,
        N_MATH_FLOOR, N_MATH_CEIL, N_MATH_ROUND, N_MATH_ABS, N_MATH_LOG, N_MATH_SQRT,
        N_MATH_SIGN, N_MATH_TRUNC, N_MATH_CLZ32, N_MATH_FROUND, N_PARSE_FLOAT, N_IS_NAN, N_IS_FINITE,
        N_ENCODE_URI, N_DECODE_URI, N_ATOB, N_BTOA, N_SET_TIMEOUT, N_SET_INTERVAL, N_CLEAR_TIMEOUT,
        N_STR_FROM_CHARCODE, N_STR_CHAR_AT, N_STR_CHAR_CODE_AT, N_STR_INDEX_OF, N_STR_INCLUDES,
        N_STR_STARTS_WITH, N_STR_ENDS_WITH, N_STR_REPEAT, N_STR_CONCAT, N_STR_MATCH, N_STR_PAD_START, N_STR_PAD_END,
        N_ARR_PUSH, N_ARR_UNSHIFT, N_ARR_INDEX_OF, N_ARR_JOIN, N_ARR_SORT, N_ARR_CONCAT,
        N_ARR_INCLUDES, N_ARR_FIND, N_ARR_MAP, N_ARR_FILTER, N_ARR_REDUCE, N_ARR_FOR_EACH,
        N_ARR_FILL, N_ARR_FLAT, N_ARR_FROM, N_ARR_IS_ARRAY, N_ARR_SOME, N_ARR_EVERY,
        N_ARRAY_CTOR, N_OBJ_KEYS, N_OBJ_VALUES, N_OBJ_ENTRIES, N_OBJ_HAS_OWN, N_OBJ_FREEZE,
        N_OBJ_GET_PROTO, N_OBJ_IS_PROTO_OF, N_OBJ_PROP_IS_ENUM, N_OBJ_OWN_NAMES, N_OBJ_IS_FROZEN,
        N_NUMBER_IS_INTEGER, N_NUMBER_IS_FINITE, N_STRING_CTOR, N_OBJECT_CTOR, N_NUMBER_CTOR,
        N_BOOLEAN_CTOR, N_ARRAY_BUFFER, N_ERROR_CTOR, N_REFERROR_CTOR, N_TYPEERROR_CTOR,
        N_REGEXP_EXEC, N_REGEXP_TEST, N_NUMBER_TO_STRING, N_FN_CALL, N_FN_BIND,
        N_SYMBOL, N_EVAL, N_FUNCTION, N_EVENT_DISPATCH, N_EVENT_CTOR => 1,
        else => 0,
    };
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
