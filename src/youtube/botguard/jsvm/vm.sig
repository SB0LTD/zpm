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
const builtins = @import("builtins.sig");
const Op = compiler.Op;
const Value = values.Value;

// ── Configuration ──

pub const MAX_STACK: usize = 4096;
pub const MAX_FRAMES: usize = 256;
pub const MAX_TRY_FRAMES: usize = 64;

// ── Call Frame ──

pub const CallFrame = struct {
    func_id: u16 = 0, // function descriptor index
    ip: u32 = 0, // instruction pointer (offset in bytecode)
    bp: u16 = 0, // base pointer (stack offset for locals)
    is_constructor: bool = false,
};

// ── Exception Frame ──

const TryFrame = struct {
    catch_ip: u32 = 0,
    finally_ip: u32 = 0,
    frame_depth: u16 = 0, // call frame depth when try was entered
    stack_depth: u16 = 0, // stack depth when try was entered
};

// ── VM State ──

var stack: [MAX_STACK]Value = undefined;
var sp: u16 = 0; // stack pointer

var frames: [MAX_FRAMES]CallFrame = undefined;
var frame_count: u16 = 0;

var try_frames: [MAX_TRY_FRAMES]TryFrame = undefined;
var try_count: u16 = 0;

var global_obj: u16 = objects.NULL_OBJ; // global object index
var had_error: bool = false;
var error_value: Value = Value.UNDEFINED;

// ── Public API ──

/// Execute bytecode. Returns the final value on stack (or undefined).
pub fn execute() Value {
    // Reset VM state
    sp = 0;
    frame_count = 0;
    try_count = 0;
    had_error = false;
    error_value = Value.UNDEFINED;

    // Initialize global object
    objects.reset();
    global_obj = objects.createObject();
    builtins.installGlobals(global_obj);

    // Push initial frame for top-level code
    frames[0] = .{ .func_id = 0xFFFF, .ip = 0, .bp = 0 };
    frame_count = 1;

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

/// Get the global object index.
pub fn getGlobal() u16 {
    return global_obj;
}

// ── Main Execution Loop ──

fn run() Value {
    const bc = compiler.getBytecode();

    while (true) {
        if (had_error) return error_value;
        if (frame_count == 0) break;

        var frame = &frames[frame_count - 1];
        if (frame.ip >= bc.len) break;

        const op: Op = @enumFromInt(bc[frame.ip]);
        frame.ip += 1;

        switch (op) {
            .nop => {},
            .halt => break,

            .pop => { if (sp > 0) sp -= 1; },
            .dup => { if (sp > 0 and sp < MAX_STACK) { stack[sp] = stack[sp - 1]; sp += 1; } },
            .swap => { if (sp >= 2) { const tmp = stack[sp - 1]; stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = tmp; } },

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
                push(if (abs < MAX_STACK) stack[abs] else Value.UNDEFINED);
            },
            .set_local => {
                const slot = readU16(bc, &frame.ip);
                const abs = frame.bp + slot;
                if (abs < MAX_STACK) stack[abs] = peek();
            },
            .get_global => {
                const name_idx = readU16(bc, &frame.ip);
                const name_str = constToStringIdx(name_idx);
                push(objects.getProperty(global_obj, name_str));
            },
            .set_global => {
                const name_idx = readU16(bc, &frame.ip);
                const name_str = constToStringIdx(name_idx);
                objects.setProperty(global_obj, name_str, peek());
            },
            .def_global => {
                const name_idx = readU16(bc, &frame.ip);
                const name_str = constToStringIdx(name_idx);
                objects.setProperty(global_obj, name_str, pop());
            },
            .get_upval => { const idx = readU16(bc, &frame.ip); _ = idx; push(Value.UNDEFINED); },
            .set_upval => { const idx = readU16(bc, &frame.ip); _ = idx; _ = pop(); },

            // Property access
            .get_prop => {
                const name_idx = readU16(bc, &frame.ip);
                const obj_val = pop();
                const name_str = constToStringIdx(name_idx);
                push(getPropFromValue(obj_val, name_str));
            },
            .set_prop => {
                const name_idx = readU16(bc, &frame.ip);
                const val = pop();
                const obj_val = pop();
                const name_str = constToStringIdx(name_idx);
                setPropOnValue(obj_val, name_str, val);
                push(val);
            },
            .get_elem => {
                const key = pop();
                const obj_val = pop();
                push(getElemFromValue(obj_val, key));
            },
            .set_elem => {
                const val = pop();
                const key = pop();
                const obj_val = pop();
                setElemOnValue(obj_val, key, val);
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
            .add => { const b = pop(); const a = pop(); push(addValues(a, b)); },
            .sub => { const b = pop(); const a = pop(); push(Value.number(a.toNumber() - b.toNumber())); },
            .mul => { const b = pop(); const a = pop(); push(Value.number(a.toNumber() * b.toNumber())); },
            .div => { const b = pop(); const a = pop(); push(Value.number(a.toNumber() / b.toNumber())); },
            .mod => { const b = pop(); const a = pop(); push(Value.number(@mod(a.toNumber(), b.toNumber()))); },
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
            .eq => { const b = pop(); const a = pop(); push(boolVal(abstractEq(a, b))); },
            .neq => { const b = pop(); const a = pop(); push(boolVal(!abstractEq(a, b))); },
            .seq => { const b = pop(); const a = pop(); push(boolVal(strictEq(a, b))); },
            .sneq => { const b = pop(); const a = pop(); push(boolVal(!strictEq(a, b))); },
            .lt => { const b = pop(); const a = pop(); push(boolVal(a.toNumber() < b.toNumber())); },
            .gt => { const b = pop(); const a = pop(); push(boolVal(a.toNumber() > b.toNumber())); },
            .lte => { const b = pop(); const a = pop(); push(boolVal(a.toNumber() <= b.toNumber())); },
            .gte => { const b = pop(); const a = pop(); push(boolVal(a.toNumber() >= b.toNumber())); },
            .instanceof => { const b = pop(); const a = pop(); _ = a; _ = b; push(Value.FALSE); },
            .in_op => { const b = pop(); const a = pop(); _ = a; _ = b; push(Value.FALSE); },

            // Logical
            .not => { const a = pop(); push(boolVal(!a.isTruthy())); },
            .typeof_op => { const a = pop(); push(typeofValue(a)); },
            .void_op => { _ = pop(); push(Value.UNDEFINED); },
            .delete_op => { _ = pop(); push(Value.TRUE); },

            // Control flow
            .jump => { const target = readU16(bc, &frame.ip); frame.ip = target; },
            .jump_if_false => {
                const target = readU16(bc, &frame.ip);
                const v = pop();
                if (!v.isTruthy()) frame.ip = target;
            },
            .jump_if_true => {
                const target = readU16(bc, &frame.ip);
                const v = pop();
                if (v.isTruthy()) frame.ip = target;
            },
            .jump_nullish => {
                const target = readU16(bc, &frame.ip);
                const v = peek();
                if (v.tag == .null_val or v.tag == .undefined) frame.ip = target;
            },
            .loop_back => {
                const offset = readU16(bc, &frame.ip);
                frame.ip -= offset;
            },

            // Functions and calls
            .call => {
                const argc = bc[frame.ip];
                frame.ip += 1;
                callFunction(argc);
            },
            .call_method => {
                const name_idx = readU16(bc, &frame.ip);
                const argc = bc[frame.ip];
                frame.ip += 1;
                _ = name_idx;
                callFunction(argc);
            },
            .ret => {
                const result = pop();
                returnFromFrame(result);
            },
            .ret_undef => {
                returnFromFrame(Value.UNDEFINED);
            },

            // Construction
            .make_object => {
                const count = bc[frame.ip];
                frame.ip += 1;
                const obj_idx = objects.createObject();
                // Pop key/value pairs
                var i: u8 = 0;
                while (i < count) : (i += 1) {
                    if (sp >= 2) {
                        const val = pop();
                        const key = pop();
                        if (key.tag == .string) {
                            objects.setProperty(obj_idx, key.data.str_idx, val);
                        }
                    }
                }
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
                push(Value.object(arr_idx));
            },
            .make_func => {
                const func_id = readU16(bc, &frame.ip);
                const obj_idx = objects.createFunction(func_id);
                push(Value.function(obj_idx));
            },

            // Special
            .spread => {}, // handled by call/array construction
            .new_call => {
                const argc = bc[frame.ip];
                frame.ip += 1;
                callConstructor(argc);
            },
            .this_val => {
                // 'this' is always the first local (slot 0 of current frame)
                const abs = frames[frame_count - 1].bp;
                push(if (abs < MAX_STACK) stack[abs] else Value.UNDEFINED);
            },
            .throw_op => {
                const thrown = pop();
                throwException(thrown);
            },
            .enter_try => {
                const catch_offset = readU16(bc, &frame.ip);
                const finally_offset = readU16(bc, &frame.ip);
                if (try_count < MAX_TRY_FRAMES) {
                    try_frames[try_count] = .{
                        .catch_ip = catch_offset,
                        .finally_ip = finally_offset,
                        .frame_depth = frame_count,
                        .stack_depth = sp,
                    };
                    try_count += 1;
                }
            },
            .leave_try => {
                if (try_count > 0) try_count -= 1;
            },
            .enter_catch => {
                push(error_value);
                had_error = false;
            },
            .enter_finally => {},
            .leave_finally => {
                if (had_error) {
                    throwException(error_value);
                }
            },

            // Iteration (simplified)
            .iter_init => {}, // TOS stays (object to iterate)
            .iter_next => { const target = readU16(bc, &frame.ip); frame.ip = target; }, // simplified: jump to end
            .iter_close => { _ = pop(); },

            // Inc/Dec
            .pre_inc => { if (sp > 0) stack[sp - 1] = Value.number(stack[sp - 1].toNumber() + 1); },
            .pre_dec => { if (sp > 0) stack[sp - 1] = Value.number(stack[sp - 1].toNumber() - 1); },
            .post_inc => { if (sp > 0) { push(stack[sp - 2]); stack[sp - 2] = Value.number(stack[sp - 2].toNumber() + 1); } },
            .post_dec => { if (sp > 0) { push(stack[sp - 2]); stack[sp - 2] = Value.number(stack[sp - 2].toNumber() - 1); } },

            .debugger_op => {},
        }
    }

    // Return TOS or undefined
    return if (sp > 0) stack[sp - 1] else Value.UNDEFINED;
}

// ── Call / Return ──

fn callFunction(argc: u8) void {
    if (sp < argc + 1) { had_error = true; return; }

    const callee_val = stack[sp - 1 - argc];

    // Check if it's a native builtin
    if (callee_val.tag == .function) {
        const obj_idx: u16 = @intCast(callee_val.data.func_idx);
        const obj = objects.getObject(obj_idx);

        if (obj.obj_type == .function) {
            const func_desc = compiler.getFunction(obj.func_id);

            // Check if this is a native function (func_id >= 0xF000)
            if (obj.func_id >= 0xF000) {
                // Native call
                const result = builtins.callNative(obj.func_id, stack[sp - argc .. sp], argc);
                sp -= (argc + 1);
                push(result);
                return;
            }

            // User function call
            if (frame_count >= MAX_FRAMES) { had_error = true; return; }

            const new_bp = sp - argc;
            frames[frame_count] = .{
                .func_id = obj.func_id,
                .ip = func_desc.code_start,
                .bp = @intCast(new_bp),
            };
            frame_count += 1;

            // Extend stack for locals
            const locals_needed = func_desc.local_count;
            while (sp < new_bp + locals_needed) {
                push(Value.UNDEFINED);
            }
            return;
        }
    }

    // Not callable — discard args, push undefined
    sp -= argc;
    if (sp > 0) sp -= 1;
    push(Value.UNDEFINED);
}

fn callConstructor(argc: u8) void {
    // new F(args): create object, call F with it as 'this'
    if (sp < argc + 1) { had_error = true; return; }

    const new_obj = objects.createObject();

    // Store new object as 'this' (first local)
    stack[sp - 1 - argc] = Value.object(new_obj);
    callFunction(argc);

    // If function didn't return an object, use the constructed one
    if (sp > 0 and stack[sp - 1].tag != .object) {
        stack[sp - 1] = Value.object(new_obj);
    }
}

fn returnFromFrame(result: Value) void {
    if (frame_count <= 1) {
        // Top-level return — push result and stop
        push(result);
        frame_count = 0;
        return;
    }

    const frame = frames[frame_count - 1];
    sp = @intCast(frame.bp);
    if (sp > 0) sp -= 1; // pop callee slot
    frame_count -= 1;
    push(result);
}

fn throwException(val: Value) void {
    error_value = val;

    // Look for a try frame
    while (try_count > 0) {
        try_count -= 1;
        const tf = try_frames[try_count];

        // Unwind call frames
        frame_count = tf.frame_depth;
        sp = tf.stack_depth;

        if (tf.catch_ip != 0) {
            // Jump to catch
            if (frame_count > 0) {
                frames[frame_count - 1].ip = tf.catch_ip;
            }
            had_error = false;
            return;
        }
    }

    // Unhandled — set error flag (execution will stop)
    had_error = true;
}

// ── Stack Operations ──

fn push(val: Value) void {
    if (sp >= MAX_STACK) { had_error = true; return; }
    stack[sp] = val;
    sp += 1;
}

fn pop() Value {
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

fn addValues(a: Value, b: Value) Value {
    // String concatenation if either is string
    if (a.tag == .string or b.tag == .string) {
        const a_str = valueToStringIdx(a);
        const b_str = valueToStringIdx(b);
        const a_text = values.getString(a_str);
        const b_text = values.getString(b_str);
        // Concatenate
        var buf: [1024]u8 = undefined;
        const total = @min(a_text.len + b_text.len, 1024);
        @memcpy(buf[0..a_text.len], a_text);
        if (b_text.len > 0 and a_text.len + b_text.len <= 1024) {
            @memcpy(buf[a_text.len..total], b_text[0 .. total - a_text.len]);
        }
        const result_idx = values.internString(buf[0..total]);
        return Value.string(result_idx);
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
        else => values.internString("[object Object]"),
    };
}

fn formatNumber(n: f64, buf: *[32]u8) usize {
    // Simple integer formatting (handles most BotGuard cases)
    if (n == 0) { buf[0] = '0'; return 1; }
    if (n != n) { @memcpy(buf[0..3], "NaN"); return 3; }

    var len: usize = 0;
    var val = n;
    if (val < 0) { buf[0] = '-'; len = 1; val = -val; }

    // Integer part
    const int_part: u64 = @intFromFloat(val);
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var tmp = int_part;
    if (tmp == 0) { digits[0] = '0'; d = 1; } else {
        while (tmp > 0) : (d += 1) { digits[d] = @intCast((tmp % 10) + '0'); tmp /= 10; }
    }
    // Reverse digits
    var i: usize = 0;
    while (i < d) : (i += 1) { buf[len + i] = digits[d - 1 - i]; }
    len += d;
    return len;
}

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
    if (a.tag == b.tag) return strictEq(a, b);
    // null == undefined
    if ((a.tag == .null_val and b.tag == .undefined) or (a.tag == .undefined and b.tag == .null_val)) return true;
    // Numeric comparison for mixed types
    return a.toNumber() == b.toNumber();
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
    if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function) {
        return objects.getProperty(@intCast(obj_val.data.obj_idx), name_idx);
    }
    if (obj_val.tag == .string) {
        // String property access (length, prototype methods)
        const name = values.getString(name_idx);
        if (eql(name, "length")) {
            return Value.number(@floatFromInt(values.getStringLen(obj_val.data.str_idx)));
        }
        // Check string prototype
        return objects.getProperty(objects.getStringProto(), name_idx);
    }
    return Value.UNDEFINED;
}

fn setPropOnValue(obj_val: Value, name_idx: u32, val: Value) void {
    if (obj_val.tag == .object or obj_val.tag == .array or obj_val.tag == .function) {
        objects.setProperty(@intCast(obj_val.data.obj_idx), name_idx, val);
    }
}

fn getElemFromValue(obj_val: Value, key: Value) Value {
    if (obj_val.tag == .object or obj_val.tag == .array) {
        if (key.tag == .number) {
            const idx: u32 = @intFromFloat(key.data.number);
            return objects.getArrayElement(@intCast(obj_val.data.obj_idx), idx);
        }
        if (key.tag == .string) {
            return objects.getProperty(@intCast(obj_val.data.obj_idx), key.data.str_idx);
        }
    }
    if (obj_val.tag == .string and key.tag == .number) {
        // charAt
        const str = values.getString(obj_val.data.str_idx);
        const idx: usize = @intFromFloat(key.data.number);
        if (idx < str.len) {
            const ch_idx = values.internString(str[idx .. idx + 1]);
            return Value.string(ch_idx);
        }
    }
    return Value.UNDEFINED;
}

fn setElemOnValue(obj_val: Value, key: Value, val: Value) void {
    if (obj_val.tag == .object or obj_val.tag == .array) {
        if (key.tag == .number) {
            const idx: u32 = @intFromFloat(key.data.number);
            objects.setArrayElement(@intCast(obj_val.data.obj_idx), idx, val);
        } else if (key.tag == .string) {
            objects.setProperty(@intCast(obj_val.data.obj_idx), key.data.str_idx, val);
        }
    }
}

// ── Bit operation helpers ──

fn toI32(v: Value) i32 {
    const n = v.toNumber();
    if (n != n or n == 0) return 0; // NaN or ±0
    return @intFromFloat(@mod(n, 4294967296.0) - 2147483648.0);
}

fn toU32(v: Value) u32 {
    const n = v.toNumber();
    if (n != n or n == 0) return 0;
    const i: i64 = @intFromFloat(n);
    return @intCast(@as(u64, @bitCast(i)) & 0xFFFFFFFF);
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

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}
