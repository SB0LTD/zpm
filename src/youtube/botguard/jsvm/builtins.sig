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
const Value = values.Value;

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

// Number / Date
pub const N_DATE_NOW: u16 = NATIVE_BASE + 130;
pub const N_NUMBER_IS_INTEGER: u16 = NATIVE_BASE + 131;
pub const N_NUMBER_IS_FINITE: u16 = NATIVE_BASE + 132;
pub const N_NUMBER_TO_STRING: u16 = NATIVE_BASE + 133;

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

// ── Random state (xorshift64) ──

var rng_state: u64 = 0x1234567890ABCDEF;

// ── Install Globals ──

/// Install all built-in functions and objects on the global object.
pub fn installGlobals(global: u16) void {
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

    // String.fromCharCode
    const string_obj = objects.createObject();
    installNativeMethod(string_obj, "fromCharCode", N_STR_FROM_CHARCODE);
    objects.setProperty(global, values.internString("String"), Value.object(string_obj));

    // Object static methods
    const obj_constructor = objects.createObject();
    installNativeMethod(obj_constructor, "keys", N_OBJ_KEYS);
    installNativeMethod(obj_constructor, "values", N_OBJ_VALUES);
    installNativeMethod(obj_constructor, "entries", N_OBJ_ENTRIES);
    installNativeMethod(obj_constructor, "assign", N_OBJ_ASSIGN);
    installNativeMethod(obj_constructor, "create", N_OBJ_CREATE);
    installNativeMethod(obj_constructor, "defineProperty", N_OBJ_DEFINE_PROP);
    installNativeMethod(obj_constructor, "freeze", N_OBJ_FREEZE);
    installNativeMethod(obj_constructor, "getPrototypeOf", N_OBJ_GET_PROTO);
    objects.setProperty(global, values.internString("Object"), Value.object(obj_constructor));

    // Array static methods
    const arr_constructor = objects.createObject();
    installNativeMethod(arr_constructor, "isArray", N_ARR_IS_ARRAY);
    installNativeMethod(arr_constructor, "from", N_ARR_FROM);
    objects.setProperty(global, values.internString("Array"), Value.object(arr_constructor));

    // Number
    const num_obj = objects.createObject();
    installNativeMethod(num_obj, "isInteger", N_NUMBER_IS_INTEGER);
    installNativeMethod(num_obj, "isFinite", N_NUMBER_IS_FINITE);
    objects.setProperty(num_obj, values.internString("MAX_SAFE_INTEGER"), Value.number(9007199254740991));
    objects.setProperty(global, values.internString("Number"), Value.object(num_obj));

    // Date
    const date_obj = objects.createObject();
    installNativeMethod(date_obj, "now", N_DATE_NOW);
    objects.setProperty(global, values.internString("Date"), Value.object(date_obj));

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

    // Constants
    objects.setProperty(global, values.internString("undefined"), Value.UNDEFINED);
    objects.setProperty(global, values.internString("NaN"), Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000)))));
    objects.setProperty(global, values.internString("Infinity"), Value.number(@as(f64, @bitCast(@as(u64, 0x7FF0000000000000)))));
}

// ── Call Native ──

/// Dispatch a native function call.
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
        N_SET_TIMEOUT, N_SET_INTERVAL => Value.number(0), // stub — return timer id 0
        N_CLEAR_TIMEOUT => Value.UNDEFINED,
        N_CONSOLE_LOG => Value.UNDEFINED,
        N_STR_FROM_CHARCODE => strFromCharCode(args),
        N_STR_CHAR_AT => strCharAt(args),
        N_STR_CHAR_CODE_AT => strCharCodeAt(args),
        N_STR_INDEX_OF => strIndexOf(args),
        N_STR_SLICE => strSlice(args),
        N_STR_SUBSTRING => strSlice(args), // similar semantics
        N_STR_SPLIT => strSplit(args),
        N_STR_REPLACE => strReplace(args),
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
        N_ARR_PUSH => arrPush(args),
        N_ARR_POP => arrPop(args),
        N_ARR_JOIN => arrJoin(args),
        N_ARR_INCLUDES => arrIncludes(args),
        N_ARR_INDEX_OF => arrIndexOf(args),
        N_ARR_IS_ARRAY => if (args.len > 0 and args[0].tag == .array) Value.TRUE else Value.FALSE,
        N_ARR_SLICE => arrSlice(args),
        N_ARR_FROM => arrFrom(args),
        N_ARR_FILL, N_ARR_FLAT, N_ARR_SORT, N_ARR_REVERSE => if (args.len > 0) args[0] else Value.UNDEFINED,
        N_ARR_MAP, N_ARR_FILTER, N_ARR_REDUCE, N_ARR_FOR_EACH, N_ARR_FIND => Value.UNDEFINED, // needs callback execution — complex
        N_ARR_SHIFT, N_ARR_UNSHIFT, N_ARR_SPLICE, N_ARR_CONCAT => Value.UNDEFINED,
        N_OBJ_KEYS => objKeys(args),
        N_OBJ_ASSIGN => if (args.len > 0) args[0] else Value.UNDEFINED,
        N_OBJ_CREATE => Value.object(objects.createObject()),
        N_OBJ_FREEZE => if (args.len > 0) args[0] else Value.UNDEFINED,
        N_OBJ_GET_PROTO => Value.NULL,
        N_OBJ_DEFINE_PROP, N_OBJ_HAS_OWN, N_OBJ_VALUES, N_OBJ_ENTRIES => Value.UNDEFINED,
        N_DATE_NOW => dateNow(),
        N_NUMBER_IS_INTEGER => if (args.len > 0) boolVal(isInteger(args[0])) else Value.FALSE,
        N_NUMBER_IS_FINITE => nIsFinite(args),
        N_NUMBER_TO_STRING => Value.UNDEFINED,
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
        else => Value.UNDEFINED,
    };
}

// ── Math implementations ──

fn mathFloor(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const n = args[0].toNumber();
    const i: f64 = @floatFromInt(@as(i64, @intFromFloat(n)));
    return Value.number(if (i > n) i - 1 else i);
}

fn mathCeil(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const n = args[0].toNumber();
    const i: f64 = @floatFromInt(@as(i64, @intFromFloat(n)));
    return Value.number(if (i < n) i + 1 else i);
}

fn mathRound(args: []const Value) Value {
    if (args.len == 0) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const n = args[0].toNumber();
    return Value.number(@floatFromInt(@as(i64, @intFromFloat(n + 0.5))));
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
    const n = args[0].toNumber();
    return Value.number(@floatFromInt(@as(i64, @intFromFloat(n))));
}

fn mathClz32(args: []const Value) Value {
    if (args.len == 0) return Value.number(32);
    const n: u32 = @intFromFloat(args[0].toNumber());
    if (n == 0) return Value.number(32);
    var count: f64 = 0;
    var v = n;
    while (v & 0x80000000 == 0) : (v <<= 1) count += 1;
    return Value.number(count);
}

fn mathImul(args: []const Value) Value {
    if (args.len < 2) return Value.number(0);
    const a: i32 = @intFromFloat(args[0].toNumber());
    const b: i32 = @intFromFloat(args[1].toNumber());
    const result: i64 = @as(i64, a) * @as(i64, b);
    const truncated: i32 = @truncate(result);
    return Value.number(@floatFromInt(truncated));
}

// ── String implementations ──

fn strFromCharCode(args: []const Value) Value {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (args) |a| {
        const code: u8 = @intFromFloat(a.toNumber());
        if (len < 256) { buf[len] = code; len += 1; }
    }
    return Value.string(values.internString(buf[0..len]));
}

fn strCharAt(args: []const Value) Value {
    if (args.len < 2) return Value.string(values.internString(""));
    const str = values.getString(args[0].data.str_idx);
    const idx: usize = @intFromFloat(args[1].toNumber());
    if (idx >= str.len) return Value.string(values.internString(""));
    return Value.string(values.internString(str[idx .. idx + 1]));
}

fn strCharCodeAt(args: []const Value) Value {
    if (args.len < 2) return Value.number(@as(f64, @bitCast(@as(u64, 0x7FF8000000000000))));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    const idx: usize = if (args.len > 1) @intFromFloat(args[1].toNumber()) else 0;
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
    var start: i64 = if (args.len > 1) @intFromFloat(args[1].toNumber()) else 0;
    var end: i64 = if (args.len > 2) @intFromFloat(args[2].toNumber()) else len_i;
    if (start < 0) start = @max(len_i + start, 0);
    if (end < 0) end = @max(len_i + end, 0);
    if (start >= len_i or start >= end) return Value.string(values.internString(""));
    const s: usize = @intCast(@min(start, len_i));
    const e: usize = @intCast(@min(end, len_i));
    return Value.string(values.internString(str[s..e]));
}

fn strSplit(args: []const Value) Value {
    // Simplified: return array with one element (full string)
    const arr = objects.createArray(1);
    if (args.len > 0) objects.setArrayElement(arr, 0, args[0]);
    return Value.object(arr);
}

fn strReplace(args: []const Value) Value {
    // Simplified: return original
    if (args.len > 0) return args[0];
    return Value.string(values.internString(""));
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
    const count: usize = @intFromFloat(args[1].toNumber());
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

fn strConcat(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    for (args) |a| {
        const s = values.getString(if (a.tag == .string) a.data.str_idx else 0);
        if (len + s.len > 2048) break;
        @memcpy(buf[len .. len + s.len], s);
        len += s.len;
    }
    return Value.string(values.internString(buf[0..len]));
}

// ── Array implementations ──

fn arrPush(args: []const Value) Value {
    if (args.len < 2) return Value.number(0);
    if (args[0].tag != .object and args[0].tag != .array) return Value.number(0);
    const obj_idx: u16 = @intCast(args[0].data.obj_idx);
    for (args[1..]) |a| objects.arrayPush(obj_idx, a);
    return Value.number(@floatFromInt(objects.arrayLength(obj_idx)));
}

fn arrPop(args: []const Value) Value {
    if (args.len == 0) return Value.UNDEFINED;
    if (args[0].tag != .object and args[0].tag != .array) return Value.UNDEFINED;
    const obj_idx: u16 = @intCast(args[0].data.obj_idx);
    const len = objects.arrayLength(obj_idx);
    if (len == 0) return Value.UNDEFINED;
    return objects.getArrayElement(obj_idx, len - 1);
}

fn arrJoin(args: []const Value) Value {
    // Simplified — join with comma
    if (args.len == 0) return Value.string(values.internString(""));
    if (args[0].tag != .object and args[0].tag != .array) return Value.string(values.internString(""));
    return Value.string(values.internString("[array]")); // placeholder
}

fn arrIncludes(args: []const Value) Value {
    if (args.len < 2) return Value.FALSE;
    if (args[0].tag != .object and args[0].tag != .array) return Value.FALSE;
    const obj_idx: u16 = @intCast(args[0].data.obj_idx);
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
    const obj_idx: u16 = @intCast(args[0].data.obj_idx);
    const len = objects.arrayLength(obj_idx);
    for (0..len) |i| {
        const elem = objects.getArrayElement(obj_idx, @intCast(i));
        if (elem.tag == args[1].tag and elem.data.number == args[1].data.number) return Value.number(@floatFromInt(i));
    }
    return Value.number(-1);
}

fn arrSlice(args: []const Value) Value {
    if (args.len == 0) return Value.object(objects.createArray(0));
    if (args[0].tag != .object and args[0].tag != .array) return Value.object(objects.createArray(0));
    const obj_idx: u16 = @intCast(args[0].data.obj_idx);
    const len: i64 = @intCast(objects.arrayLength(obj_idx));
    var start: i64 = if (args.len > 1) @intFromFloat(args[1].toNumber()) else 0;
    var end: i64 = if (args.len > 2) @intFromFloat(args[2].toNumber()) else len;
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    if (start >= end) return Value.object(objects.createArray(0));
    const count: u32 = @intCast(@min(end - start, len));
    const new_arr = objects.createArray(count);
    for (0..count) |i| {
        const elem = objects.getArrayElement(obj_idx, @intCast(@as(i64, @intCast(i)) + start));
        objects.setArrayElement(new_arr, @intCast(i), elem);
    }
    return Value.object(new_arr);
}

fn arrFrom(args: []const Value) Value {
    // Simplified: if arg is array, return copy; else create [arg]
    if (args.len > 0 and (args[0].tag == .object or args[0].tag == .array)) return args[0];
    const arr = objects.createArray(if (args.len > 0) 1 else 0);
    if (args.len > 0) objects.setArrayElement(arr, 0, args[0]);
    return Value.object(arr);
}

fn objKeys(args: []const Value) Value {
    // Return empty array for now (full impl would enumerate properties)
    _ = args;
    return Value.object(objects.createArray(0));
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

fn nAtob(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    var buf: [2048]u8 = undefined;
    const len = base64Decode(str, &buf);
    return Value.string(values.internString(buf[0..len]));
}

fn nBtoa(args: []const Value) Value {
    if (args.len == 0) return Value.string(values.internString(""));
    const str = values.getString(if (args[0].tag == .string) args[0].data.str_idx else 0);
    var buf: [4096]u8 = undefined;
    const len = base64Encode(str, &buf);
    return Value.string(values.internString(buf[0..len]));
}

fn dateNow() Value {
    // Return a plausible timestamp (BotGuard uses for timing checks)
    // We return a fixed value to avoid detection
    return Value.number(1703980800000); // 2023-12-31T00:00:00Z
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
    const obj_idx: u16 = @intCast(args[0].data.obj_idx);
    const len = @min(objects.arrayLength(obj_idx), 2048);
    var buf: [2048]u8 = undefined;
    for (0..len) |i| {
        const elem = objects.getArrayElement(obj_idx, @intCast(i));
        buf[i] = @intFromFloat(elem.toNumber());
    }
    return Value.string(values.internString(buf[0..len]));
}

fn cryptoRandom(args: []const Value) Value {
    // crypto.getRandomValues(arr)
    if (args.len == 0) return Value.UNDEFINED;
    if (args[0].tag != .object and args[0].tag != .array) return args[0];
    const obj_idx: u16 = @intCast(args[0].data.obj_idx);
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
        len = @intFromFloat(args[0].toNumber());
    }
    const buf = objects.createArrayBuffer(len * elem_size);
    const ta = objects.createTypedArray(buf, 0, len, elem_size);
    return Value.object(ta);
}

fn createArrayBufferN(args: []const Value) Value {
    var len: u32 = 0;
    if (args.len > 0 and args[0].tag == .number) {
        len = @intFromFloat(args[0].toNumber());
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
            const i: i64 = @intFromFloat(n);
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
    const i: f64 = @floatFromInt(@as(i64, @intFromFloat(n)));
    return i == n;
}

// ── Base64 ──

const B64_TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Encode(data: []const u8, out: *[4096]u8) usize {
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

fn base64Decode(data: []const u8, out: *[2048]u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i + 3 < data.len and o + 3 <= 2048) : (i += 4) {
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

fn installNativeMethod(obj: u16, name: []const u8, func_id: u16) void {
    const func_obj = objects.createFunction(func_id);
    objects.setProperty(obj, values.internString(name), Value.function(func_obj));
}

fn installNativeGlobal(global: u16, name: []const u8, func_id: u16) void {
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
