// @zpm/youtube/botguard/jsvm/objects — Object/Array/Function Runtime
//
// Implements the JavaScript object model for the VM:
//   - Object: property map with prototype chain
//   - Array: indexed + named properties
//   - Function: callable with closure/upvalues
//   - Prototype chain lookup (Object.getPrototypeOf)
//   - Getters/setters
//   - Typed arrays (Uint8Array, ArrayBuffer, DataView)
//
// Fixed-size pools — no heap allocation.

const values = @import("values.sig");
const Value = values.Value;

// ── Configuration ──

pub const MAX_OBJECTS: usize = 8192;
pub const MAX_PROPERTIES: usize = 65536; // total property slots across all objects
pub const MAX_ARRAY_ELEMENTS: usize = 131072; // total array element slots
pub const MAX_CLOSURES: usize = 4096;

// ── Object representation ──

pub const ObjType = enum(u8) {
    object,
    array,
    function,
    typed_array,
    array_buffer,
    data_view,
    regexp,
    promise,
    proxy,
    date,
};

pub const Object = struct {
    obj_type: ObjType = .object,
    prototype: u16 = NULL_OBJ, // index into objects pool
    prop_start: u32 = 0, // index into property pool
    prop_count: u16 = 0,
    // Array-specific
    array_start: u32 = 0, // index into array_elements pool
    array_len: u32 = 0,
    // Function-specific
    func_id: u16 = 0, // index into compiler's function descriptors
    closure_id: u16 = NULL_OBJ, // upvalue frame
    // Typed array specific
    buffer_id: u16 = NULL_OBJ, // underlying ArrayBuffer object
    byte_offset: u32 = 0,
    byte_length: u32 = 0,
    elem_size: u8 = 1, // 1, 2, or 4
    is_frozen: bool = false,
    is_sealed: bool = false,
};

pub const NULL_OBJ: u16 = 0xFFFF;

/// A property entry.
pub const Property = struct {
    name_idx: u32 = 0, // string pool index for property name
    value: Value = Value.UNDEFINED,
    flags: PropFlags = .{},
};

pub const PropFlags = packed struct(u8) {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
    is_getter: bool = false,
    is_setter: bool = false,
    _pad: u3 = 0,
};

// ── Closure / Upvalue ──

pub const MAX_UPVALUES_TOTAL: usize = 8192;

pub const UpvalueSlot = struct {
    value: Value = Value.UNDEFINED,
    is_open: bool = true, // still on stack vs closed over
    stack_idx: u16 = 0, // if open, which stack slot
};

// ── Pools ──

var objects: [MAX_OBJECTS]Object = undefined;
var n_objects: u16 = 0;

var properties: [MAX_PROPERTIES]Property = undefined;
var n_properties: u32 = 0;

var array_elements: [MAX_ARRAY_ELEMENTS]Value = undefined;
var n_array_elems: u32 = 0;

var upvalue_pool: [MAX_UPVALUES_TOTAL]UpvalueSlot = undefined;
var n_upvalues: u16 = 0;

// ── Well-known prototype objects ──
var object_proto: u16 = NULL_OBJ;
var array_proto: u16 = NULL_OBJ;
var function_proto: u16 = NULL_OBJ;
var string_proto: u16 = NULL_OBJ;
var number_proto: u16 = NULL_OBJ;
var boolean_proto: u16 = NULL_OBJ;

// ── Public API ──

/// Reset all object pools.
pub fn reset() void {
    n_objects = 0;
    n_properties = 0;
    n_array_elems = 0;
    n_upvalues = 0;

    // Create base prototypes
    object_proto = allocObject(.object);
    array_proto = allocObject(.object);
    function_proto = allocObject(.object);
    string_proto = allocObject(.object);
    number_proto = allocObject(.object);
    boolean_proto = allocObject(.object);
}

/// Get the Object.prototype index.
pub fn getObjectProto() u16 { return object_proto; }
pub fn getArrayProto() u16 { return array_proto; }
pub fn getFunctionProto() u16 { return function_proto; }
pub fn getStringProto() u16 { return string_proto; }

/// Create a new plain object.
pub fn createObject() u16 {
    const idx = allocObject(.object);
    if (idx != NULL_OBJ) objects[idx].prototype = object_proto;
    return idx;
}

/// Create a new array with given capacity.
pub fn createArray(initial_len: u32) u16 {
    const idx = allocObject(.array);
    if (idx == NULL_OBJ) return NULL_OBJ;
    objects[idx].prototype = array_proto;
    objects[idx].array_start = n_array_elems;
    objects[idx].array_len = initial_len;

    // Reserve space
    const space = @min(initial_len, MAX_ARRAY_ELEMENTS - n_array_elems);
    for (0..space) |i| {
        array_elements[n_array_elems + @as(u32, @intCast(i))] = Value.UNDEFINED;
    }
    n_array_elems += space;
    return idx;
}

/// Create a function object.
pub fn createFunction(func_id: u16) u16 {
    const idx = allocObject(.function);
    if (idx == NULL_OBJ) return NULL_OBJ;
    objects[idx].prototype = function_proto;
    objects[idx].func_id = func_id;
    return idx;
}

/// Create a typed array (Uint8Array, etc.).
pub fn createTypedArray(buffer_id: u16, byte_offset: u32, length: u32, elem_size: u8) u16 {
    const idx = allocObject(.typed_array);
    if (idx == NULL_OBJ) return NULL_OBJ;
    objects[idx].buffer_id = buffer_id;
    objects[idx].byte_offset = byte_offset;
    objects[idx].byte_length = length * elem_size;
    objects[idx].elem_size = elem_size;
    return idx;
}

/// Create an ArrayBuffer.
pub fn createArrayBuffer(byte_length: u32) u16 {
    const idx = allocObject(.array_buffer);
    if (idx == NULL_OBJ) return NULL_OBJ;
    // Use array_elements pool for buffer storage (4 bytes per element slot)
    objects[idx].array_start = n_array_elems;
    objects[idx].byte_length = byte_length;
    const slots_needed = (byte_length + 7) / 8; // Value is 16 bytes, but we pack
    const space = @min(slots_needed, MAX_ARRAY_ELEMENTS - n_array_elems);
    n_array_elems += space;
    return idx;
}

/// Get an object by index.
pub fn getObject(idx: u16) *Object {
    if (idx >= n_objects) return &objects[0]; // safety fallback
    return &objects[idx];
}

/// Set a property on an object.
pub fn setProperty(obj_idx: u16, name_idx: u32, val: Value) void {
    if (obj_idx >= n_objects) return;
    const obj = &objects[obj_idx];

    // Check if property already exists
    var i: u32 = obj.prop_start;
    const end = obj.prop_start + obj.prop_count;
    while (i < end) : (i += 1) {
        if (properties[i].name_idx == name_idx) {
            if (properties[i].flags.writable) {
                properties[i].value = val;
            }
            return;
        }
    }

    // Add new property
    if (n_properties >= MAX_PROPERTIES) return;
    if (obj.prop_count == 0) {
        obj.prop_start = n_properties;
    }
    properties[n_properties] = .{ .name_idx = name_idx, .value = val };
    n_properties += 1;
    obj.prop_count += 1;
}

/// Get a property from an object (with prototype chain).
pub fn getProperty(obj_idx: u16, name_idx: u32) Value {
    var current = obj_idx;
    var depth: u8 = 0;
    while (current != NULL_OBJ and depth < 32) : (depth += 1) {
        if (current >= n_objects) return Value.UNDEFINED;
        const obj = objects[current];
        var i: u32 = obj.prop_start;
        const end = obj.prop_start + obj.prop_count;
        while (i < end) : (i += 1) {
            if (properties[i].name_idx == name_idx) {
                return properties[i].value;
            }
        }
        current = obj.prototype;
    }
    return Value.UNDEFINED;
}

/// Check if object has own property.
pub fn hasOwnProperty(obj_idx: u16, name_idx: u32) bool {
    if (obj_idx >= n_objects) return false;
    const obj = objects[obj_idx];
    var i: u32 = obj.prop_start;
    const end = obj.prop_start + obj.prop_count;
    while (i < end) : (i += 1) {
        if (properties[i].name_idx == name_idx) return true;
    }
    return false;
}

/// Get array element by index.
pub fn getArrayElement(obj_idx: u16, index: u32) Value {
    if (obj_idx >= n_objects) return Value.UNDEFINED;
    const obj = objects[obj_idx];
    if (index >= obj.array_len) return Value.UNDEFINED;
    const abs_idx = obj.array_start + index;
    if (abs_idx >= n_array_elems) return Value.UNDEFINED;
    return array_elements[abs_idx];
}

/// Set array element by index.
pub fn setArrayElement(obj_idx: u16, index: u32, val: Value) void {
    if (obj_idx >= n_objects) return;
    const obj = &objects[obj_idx];
    // Grow if needed
    if (index >= obj.array_len) {
        obj.array_len = index + 1;
    }
    const abs_idx = obj.array_start + index;
    if (abs_idx >= MAX_ARRAY_ELEMENTS) return;
    if (abs_idx >= n_array_elems) n_array_elems = abs_idx + 1;
    array_elements[abs_idx] = val;
}

/// Push element to array.
pub fn arrayPush(obj_idx: u16, val: Value) void {
    if (obj_idx >= n_objects) return;
    const obj = &objects[obj_idx];
    setArrayElement(obj_idx, obj.array_len, val);
}

/// Get array length.
pub fn arrayLength(obj_idx: u16) u32 {
    if (obj_idx >= n_objects) return 0;
    return objects[obj_idx].array_len;
}

/// Allocate an upvalue slot.
pub fn allocUpvalue(stack_idx: u16) u16 {
    if (n_upvalues >= MAX_UPVALUES_TOTAL) return 0;
    const idx = n_upvalues;
    upvalue_pool[idx] = .{ .is_open = true, .stack_idx = stack_idx };
    n_upvalues += 1;
    return idx;
}

/// Close an upvalue (capture its current value from stack).
pub fn closeUpvalue(uv_idx: u16, val: Value) void {
    if (uv_idx >= n_upvalues) return;
    upvalue_pool[uv_idx].value = val;
    upvalue_pool[uv_idx].is_open = false;
}

/// Get upvalue.
pub fn getUpvalue(uv_idx: u16) *UpvalueSlot {
    if (uv_idx >= n_upvalues) return &upvalue_pool[0];
    return &upvalue_pool[uv_idx];
}

/// Get typed array buffer pointer (as bytes in array_elements).
pub fn getBufferBytes(obj_idx: u16) []u8 {
    if (obj_idx >= n_objects) return &[_]u8{};
    const obj = objects[obj_idx];
    if (obj.obj_type != .array_buffer) return &[_]u8{};
    const start = obj.array_start;
    const byte_len = obj.byte_length;
    // Reinterpret array_elements storage as bytes
    const ptr: [*]u8 = @ptrCast(&array_elements[start]);
    return ptr[0..byte_len];
}

// ── Internal ──

fn allocObject(obj_type: ObjType) u16 {
    if (n_objects >= MAX_OBJECTS) return NULL_OBJ;
    const idx = n_objects;
    objects[idx] = .{ .obj_type = obj_type };
    n_objects += 1;
    return idx;
}
