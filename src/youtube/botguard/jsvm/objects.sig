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
const std = @import("std");

// ── Configuration ──

// BotGuard's interpreter allocates a fresh register OBJECT per register-value
// computation (Eu builds `Object.create(rD)` closures), plus many cipher/scratch
// arrays, across thousands of interpreted instructions. 8K objects exhausted
// mid-run (allocObject -> NULL_OBJ -> Value.object(0xFFFF) -> `.concat` on a
// bogus object). These pools are sized for a full BotGuard VM run.
// Object indices are u16 (NULL_OBJ = 0xFFFF), so the pool caps at 65535 entries.
// 8K exhausted mid-run; 65000 gives ~8x headroom. If BotGuard needs more, obj_idx
// must be widened to u32 (a larger change across values.sig/vm.sig).
pub const MAX_OBJECTS: usize = 1048576;
pub const MAX_PROPERTIES: usize = 2097152; // total property slots across all objects
pub const MAX_ARRAY_ELEMENTS: usize = 2097152; // total array element slots
pub const MAX_CLOSURES: usize = 65536;
// Array challenges contain more than 10K byte elements. Iteration and
// reflection share a bounded snapshot large enough for those arrays.
pub const MAX_ENUM_KEYS: usize = 16384;

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
    boxed_string,
    boxed_number,
    boxed_boolean,
};

pub const Object = struct {
    obj_type: ObjType = .object,
    extensible: bool = true,
    frozen: bool = false,
    prototype: u32 = NULL_OBJ, // index into objects pool (u32: pool may exceed 65535)
    // Properties are a singly-linked list through the property pool (objects
    // are created and mutated interleaved, so a contiguous range does not work).
    prop_head: u32 = NULL_PROP, // first property index, or NULL_PROP
    prop_count: u16 = 0,
    // Array-specific
    array_start: u32 = 0, // index into array_elements pool
    array_len: u32 = 0,
    array_length_writable: bool = true,
    // Physical capacity reserved in the pool at array_start. array_len may be
    // less than array_cap. Growing past array_cap relocates the array to the
    // end of the pool. This makes arrays safely growable despite the flat,
    // non-relocatable-in-place element pool (register banks `u.T` grow to
    // hundreds of slots at runtime and MUST NOT clobber neighbours).
    array_cap: u32 = 0,
    // Function-specific
    func_id: u16 = 0, // index into compiler's function descriptors
    // Native source identity is independent of the configurable public name.
    native_name: u32 = NULL_OBJ,
    closure_id: u32 = NULL_OBJ, // upvalue frame (object index)
    // Closure capture (by-value snapshot). Captured upvalue values live in the
    // shared closure_upvals pool at [upval_start .. upval_start + n_upvals).
    upval_start: u32 = 0,
    n_upvals: u16 = 0,
    // Typed array specific
    buffer_id: u32 = NULL_OBJ, // underlying ArrayBuffer object (object index)
    byte_offset: u32 = 0,
    byte_length: u32 = 0,
    elem_size: u8 = 1, // 1, 2, or 4
    elem_signed: bool = false,
    is_frozen: bool = false,
    is_sealed: bool = false,
    is_arguments: bool = false,
    // Internal scalar slot for Date timestamps and boxed Number values.
    number_value: f64 = 0,
    // Host receiver brand; prototype inheritance alone cannot forge a media
    // element's WebIDL internal slots.
    dom_media: bool = false,
    dom_iframe: bool = false,
    dom_srcdoc: u32 = NULL_OBJ,
    dom_window: bool = false,
    dom_iframe_window: u32 = NULL_OBJ,
    dom_node: bool = false,
    dom_parent: u32 = NULL_OBJ,
    dom_children: u32 = NULL_OBJ,
    // Debug: tags environment objects (navigator/document/window/screen/
    // location/canvas/webgl contexts) so the VM can record which properties
    // BotGuard probes on them that our env doesn't implement (fingerprint leaks).
    is_env: bool = false,
};

pub const NULL_OBJ: u32 = 0xFFFFFFFF;
pub const NULL_PROP: u32 = 0xFFFFFFFF;

/// A property entry (node in an object's singly-linked property list).
pub const Property = struct {
    name_idx: u32 = 0, // string pool index for property name
    value: Value = Value.UNDEFINED,
    next: u32 = NULL_PROP, // next property in this object, or NULL_PROP
    flags: PropFlags = .{},
    // Non-strict arguments indexes can alias a parameter's shared cell.
    mapped_cell: u32 = NO_CELL,
    setter_fn: u32 = NULL_OBJ,
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
var n_objects: u32 = 0;

var properties: [MAX_PROPERTIES]Property = undefined;
var n_properties: u32 = 0;
pub var dbg_prop_overflow: u32 = 0;
pub fn dbgPropStats() [3]u32 { return .{ n_properties, @intCast(MAX_PROPERTIES), dbg_prop_overflow }; }

var array_elements: [MAX_ARRAY_ELEMENTS]Value = undefined;
// One bit per element distinguishes an absent slot from an own property whose
// value is undefined. Length growth and deletion create absent slots.
var array_present: [(MAX_ARRAY_ELEMENTS + 63) / 64]u64 = undefined;
var n_array_elems: u32 = 0;

var upvalue_pool: [MAX_UPVALUES_TOTAL]UpvalueSlot = undefined;
var n_upvalues: u16 = 0;

// Shared pool of captured upvalue VALUES for closures (by-value capture).
// Each closure reserves a contiguous run [upval_start .. +n_upvals).
pub const MAX_CLOSURE_UPVALS: usize = 2097152;
// By-reference upvalues: each slot holds an ABSOLUTE VM stack index (the
// captured variable's live location `frame.bp + slot`). Reads/writes go
// through the live stack so writes to the variable AFTER the closure was
// created are visible (BotGuard defines Ne/pL/etc. AFTER the capturing closure
// Me is created, then Me must see them). The VM does the stack indirection;
// objects.sig just stores the addresses. Address 0xFFFFFFFF = "no capture".
pub const NO_UPVAL_ADDR: u32 = 0xFFFFFFFF;

// ── Shared upvalue cells (open-upvalue list) ──
// A closure's i-th upvalue is an INDEX into `closure_upvals` (kept for layout),
// but the actual variable lives in a SHARED CELL so that sibling closures that
// capture the same variable share ONE mutable cell — writes via one closure are
// visible to the other, both while the defining frame is live (open, cell holds
// a stack address) and after it returns (closed, cell holds the value). Without
// this, BotGuard's register objects (whose `.create`/`.concat` closures share a
// PC/E counter) can never advance and the interpreter stalls.
pub const MAX_UPVAL_CELLS: usize = 2097152;
pub const NO_CELL: u32 = 0xFFFFFFFF;
var cell_addr: [MAX_UPVAL_CELLS]u32 = undefined;   // open: live stack addr, else NO_UPVAL_ADDR
var cell_val: [MAX_UPVAL_CELLS]Value = undefined;  // closed: snapshot value
var cell_closed: [MAX_UPVAL_CELLS]bool = undefined;
var n_cells: u32 = 0;
// The VM lends its fixed operand/local storage. This keeps the object layer
// independent of the interpreter while mapped arguments share live locals.
var runtime_stack: []Value = &.{};

pub fn bindRuntimeStack(storage: []Value) void {
    runtime_stack = storage;
}

fn propertyValue(prop: *const Property) Value {
    const ci = prop.mapped_cell;
    if (ci == NO_CELL or ci >= n_cells) return prop.value;
    if (cell_closed[ci]) return cell_val[ci];
    const addr = cell_addr[ci];
    return if (addr < runtime_stack.len) runtime_stack[addr] else prop.value;
}

fn writePropertyValue(prop: *Property, value: Value) void {
    prop.value = value;
    const ci = prop.mapped_cell;
    if (ci == NO_CELL or ci >= n_cells) return;
    if (cell_closed[ci]) cell_val[ci] = value
    else if (cell_addr[ci] < runtime_stack.len) runtime_stack[cell_addr[ci]] = value;
}

/// Alias an existing own data property to a formal parameter's shared cell.
pub fn bindMappedProperty(obj_idx: u32, name_idx: u32, addr: u32) void {
    if (obj_idx >= n_objects or addr >= runtime_stack.len) return;
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        const prop = &properties[p];
        if (prop.name_idx != name_idx) continue;
        if (!prop.flags.is_getter and !prop.flags.is_setter and prop.flags.writable) prop.mapped_cell = openCellFor(addr);
        return;
    }
}
// Compact list of currently-OPEN cell indices so sibling-closure sharing scans
// only live cells (bounded by live captures), not every cell ever allocated.
var open_cells: [MAX_UPVAL_CELLS]u32 = undefined;
var n_open_cells: u32 = 0;

// Per-closure slot -> shared cell index.
var closure_upvals: [MAX_CLOSURE_UPVALS]u32 = undefined; // now stores a CELL index (or NO_CELL)
var closure_upval_vals: [MAX_CLOSURE_UPVALS]Value = undefined; // (legacy, unused by cell path)
var closure_upval_closed: [MAX_CLOSURE_UPVALS]bool = undefined; // (legacy)
var n_closure_upvals: u32 = 0;

/// Find an existing OPEN cell for `addr`, or create a new one. This is what
/// makes sibling closures share a single cell for the same captured variable.
fn openCellFor(addr: u32) u32 {
    // Scan only the compact open-cell list (small: bounded by live captures).
    var k: u32 = 0;
    while (k < n_open_cells) : (k += 1) {
        const ci = open_cells[k];
        if (cell_addr[ci] == addr) return ci; // entries here are open by construction
    }
    if (n_cells >= MAX_UPVAL_CELLS) return NO_CELL;
    const idx = n_cells;
    cell_addr[idx] = addr;
    cell_val[idx] = Value.UNDEFINED;
    cell_closed[idx] = false;
    n_cells += 1;
    if (n_open_cells < open_cells.len) { open_cells[n_open_cells] = idx; n_open_cells += 1; }
    return idx;
}

/// Allocate a fresh CLOSED cell holding a value (for transitive capture of an
/// already-closed parent upvalue).
fn newClosedCell(v: Value) u32 {
    if (n_cells >= MAX_UPVAL_CELLS) return NO_CELL;
    const idx = n_cells;
    cell_addr[idx] = NO_UPVAL_ADDR;
    cell_val[idx] = v;
    cell_closed[idx] = true;
    n_cells += 1;
    return idx;
}

// ── Well-known prototype objects ──
var object_proto: u32 = NULL_OBJ;
var array_proto: u32 = NULL_OBJ;
var function_proto: u32 = NULL_OBJ;
var string_proto: u32 = NULL_OBJ;
var number_proto: u32 = NULL_OBJ;
var boolean_proto: u32 = NULL_OBJ;
var error_proto: u32 = NULL_OBJ;

// ── Public API ──

/// Reset all object pools.
pub fn reset() void {
    values.object_number = numericObjectValue;
    n_objects = 0;
    n_properties = 0;
    n_array_elems = 0;
    n_upvalues = 0;
    n_closure_upvals = 0;
    n_cells = 0;
    n_open_cells = 0;

    // Zero-initialize the value-bearing pools. Zig leaves `undefined` module
    // storage as arbitrary bytes in ReleaseFast, so any slot read before it is
    // written (through a logic path that trusts a default UNDEFINED/NO_CELL)
    // would see per-process garbage — the source of the nondeterministic
    // interpreter stalls. A Value of all-zero bytes is exactly Value.UNDEFINED
    // (tag .undefined == 0, data == 0), so memset(0) yields valid defaults.
    @memset(array_elements[0..], Value.UNDEFINED);
    @memset(array_present[0..], 0);
    @memset(cell_val[0..], Value.UNDEFINED);
    @memset(cell_addr[0..], NO_UPVAL_ADDR);
    @memset(cell_closed[0..], false);
    @memset(open_cells[0..], 0);
    @memset(closure_upvals[0..], NO_CELL);
    @memset(closure_upval_vals[0..], Value.UNDEFINED);
    @memset(closure_upval_closed[0..], false);

    // Create base prototypes
    object_proto = allocObject(.object);
    array_proto = allocObject(.array);
    function_proto = allocObject(.function);
    string_proto = allocObject(.boxed_string);
    number_proto = allocObject(.boxed_number);
    boolean_proto = allocObject(.boxed_boolean);
    error_proto = allocObject(.object);
    // Built-in prototypes all inherit from Object.prototype in JS, so methods
    // like hasOwnProperty/toString/isPrototypeOf resolve on arrays, functions,
    // strings, numbers, booleans and errors via the prototype chain. Without
    // these links `arr.hasOwnProperty` / `fn.hasOwnProperty` would be undefined.
    if (array_proto != NULL_OBJ) objects[array_proto].prototype = object_proto;
    if (function_proto != NULL_OBJ) objects[function_proto].prototype = object_proto;
    if (string_proto != NULL_OBJ) objects[string_proto].prototype = object_proto;
    if (number_proto != NULL_OBJ) objects[number_proto].prototype = object_proto;
    if (boolean_proto != NULL_OBJ) objects[boolean_proto].prototype = object_proto;
    if (error_proto != NULL_OBJ) objects[error_proto].prototype = object_proto;
    if (string_proto != NULL_OBJ) {
        objects[string_proto].array_start = values.internString("");
        const length = values.internString("length");
        setProperty(string_proto, length, Value.number(0));
        setEnumerable(string_proto, length, false);
        setWritable(string_proto, length, false);
        setConfigurable(string_proto, length, false);
    }
}

/// Get the Object.prototype index.
pub fn getObjectProto() u32 { return object_proto; }
pub fn getArrayProto() u32 { return array_proto; }
pub fn getFunctionProto() u32 { return function_proto; }
pub fn getNumberProto() u32 { return number_proto; }
pub fn getBooleanProto() u32 { return boolean_proto; }
pub fn getStringProto() u32 { return string_proto; }
pub fn getErrorProto() u32 { return error_proto; }

/// Create a new plain object.
pub fn createObject() u32 {
    const idx = allocObject(.object);
    if (idx != NULL_OBJ) objects[idx].prototype = object_proto;
    return idx;
}

/// Set an object's internal [[Prototype]] link (used by `new F()`).
pub var dbg_nullproto_set: [32]u32 = [_]u32{0xFFFFFFFF} ** 32;
pub var dbg_nullproto_n: usize = 0;
pub var dbg_nullproto_total: u32 = 0;
pub fn dbgObjHasNullProto(obj_idx: u32) bool {
    if (obj_idx >= n_objects) return false;
    return objects[obj_idx].prototype == NULL_OBJ;
}
pub var dbg_protowatch_on: bool = false;
pub var dbg_protowatch_child: u32 = 0xFFFFFFFF;
pub var dbg_protowatch_n: usize = 0;
pub var dbg_protowatch_parent: [32]u32 = [_]u32{0} ** 32;
pub var dbg_protowatch_func: [32]u16 = [_]u16{0} ** 32;
pub var dbg_protowatch_ip: [32]u32 = [_]u32{0} ** 32;
pub fn dbgProtoWatchEnable(child: u32) void { dbg_protowatch_on = true; dbg_protowatch_child = child; dbg_protowatch_n = 0; dbg_track_active = true; }
pub fn dbgProtoWatchN() usize { return dbg_protowatch_n; }
pub fn dbgProtoWatchParent(i: usize) u32 { return dbg_protowatch_parent[i]; }
pub fn dbgProtoWatchFunc(i: usize) u16 { return dbg_protowatch_func[i]; }
pub fn dbgProtoWatchIp(i: usize) u32 { return dbg_protowatch_ip[i]; }
pub fn setObjectPrototype(obj_idx: u32, proto_idx: u32) void {
    if (obj_idx >= n_objects) return;
    if (dbg_protowatch_on and obj_idx == dbg_protowatch_child and dbg_protowatch_n < dbg_protowatch_parent.len) {
        dbg_protowatch_parent[dbg_protowatch_n] = proto_idx;
        dbg_protowatch_func[dbg_protowatch_n] = dbg_active_func;
        dbg_protowatch_ip[dbg_protowatch_n] = dbg_active_ip;
        dbg_protowatch_n += 1;
    }
    objects[obj_idx].prototype = proto_idx;
    if (proto_idx == NULL_OBJ) {
        dbg_nullproto_total += 1;
        if (dbg_nullproto_n < dbg_nullproto_set.len) { dbg_nullproto_set[dbg_nullproto_n] = obj_idx; dbg_nullproto_n += 1; }
    }
}

/// Get an object's internal [[Prototype]] index (NULL_OBJ if none/invalid).
/// Debug: report own-property status of `name_idx` on `obj_idx`.
/// 0 = absent, 1 = data property, 2 = getter, 3 = setter.
pub fn dbgOwnPropKind(obj_idx: u32, name_idx: u32) u8 {
    if (obj_idx >= n_objects) return 0;
    var p: u32 = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        if (properties[p].name_idx == name_idx) {
            if (properties[p].flags.is_getter) return 2;
            if (properties[p].flags.is_setter) return 3;
            return 1;
        }
    }
    return 0;
}

pub fn getObjectPrototypeIdx(obj_idx: u32) u32 {
    if (obj_idx >= n_objects) return NULL_OBJ;
    return objects[obj_idx].prototype;
}

/// Copy a host object's own descriptors into an empty object, preserving
/// insertion order and flags. Values reference the existing fixed arenas.
pub fn copyOwnProperties(source: u32, target: u32) bool {
    if (source >= n_objects or target >= n_objects or objects[target].prop_count != 0 or objects[source].prop_count > MAX_PROPERTIES - n_properties) return false;
    var cursor = objects[source].prop_head;
    var tail = &objects[target].prop_head;
    while (cursor != NULL_PROP) {
        const idx = n_properties;
        properties[idx] = properties[cursor];
        properties[idx].mapped_cell = NO_CELL;
        properties[idx].next = NULL_PROP;
        n_properties += 1;
        tail.* = idx;
        tail = &properties[idx].next;
        cursor = properties[cursor].next;
    }
    objects[target].prop_count = objects[source].prop_count;
    return true;
}

/// Create a new array with given capacity.
pub fn createArray(initial_len: u32) u32 {
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
    objects[idx].array_cap = space;
    n_array_elems += space;
    return idx;
}

/// Create an array that RESERVES `cap` element slots but has length 0. Because
/// arrays store elements in a contiguous, non-relocatable pool region, an array
/// that will be grown AFTER later allocations must reserve its capacity up
/// front — otherwise growing it would overwrite subsequently-allocated storage.
/// Used for host-provided output arrays (e.g. BotGuard's webPoSignalOutput)
/// that the VM fills in later.
pub fn createArrayWithCapacity(cap: u32) u32 {
    const idx = allocObject(.array);
    if (idx == NULL_OBJ) return NULL_OBJ;
    objects[idx].prototype = array_proto;
    objects[idx].array_start = n_array_elems;
    objects[idx].array_len = 0;
    const space = @min(cap, MAX_ARRAY_ELEMENTS - n_array_elems);
    for (0..space) |i| {
        array_elements[n_array_elems + @as(u32, @intCast(i))] = Value.UNDEFINED;
    }
    objects[idx].array_cap = space;
    n_array_elems += space;
    return idx;
}

/// Create a function object.
pub fn createFunction(func_id: u16) u32 {
    const idx = allocObject(.function);
    if (idx == NULL_OBJ) return NULL_OBJ;
    objects[idx].prototype = function_proto;
    objects[idx].func_id = func_id;
    return idx;
}

/// Create a closure: a function object that also reserves `n` upvalue slots.
/// Each slot stores an ABSOLUTE VM stack address (set via setClosureUpvalAddr)
/// so captures are by-reference to the live variable.
pub fn createClosure(func_id: u16, n: u16) u32 {
    const idx = allocObject(.function);
    if (idx == NULL_OBJ) return NULL_OBJ;
    objects[idx].prototype = function_proto;
    objects[idx].func_id = func_id;
    if (n > 0) {
        const start = n_closure_upvals;
        const space: u32 = @min(@as(u32, n), @as(u32, @intCast(MAX_CLOSURE_UPVALS)) - n_closure_upvals);
        objects[idx].upval_start = start;
        objects[idx].n_upvals = @intCast(space);
        var i: u32 = 0;
        while (i < space) : (i += 1) {
            closure_upvals[start + i] = NO_CELL; // no cell yet
        }
        n_closure_upvals += space;
    }
    return idx;
}

/// Function id backing a closure/function object.
pub fn getObjectProtoIdx() u32 { return object_proto; }
pub fn closureFuncId(obj_idx: u32) u16 {
    if (obj_idx >= n_objects) return 0xFFFF;
    return objects[obj_idx].func_id;
}
/// Number of upvalue slots on a closure object.
pub fn closureUpvalCount(obj_idx: u32) u16 {
    if (obj_idx >= n_objects) return 0;
    return objects[obj_idx].n_upvals;
}
/// Cell index backing a closure's i-th upvalue (NO_CELL if unset).
fn upvalCell(obj_idx: u32, i: u16) u32 {
    if (obj_idx >= n_objects) return NO_CELL;
    const obj = objects[obj_idx];
    if (i >= obj.n_upvals) return NO_CELL;
    return closure_upvals[obj.upval_start + i];
}

/// Read a closure's i-th captured upvalue value.
/// Get the absolute VM stack address stored in a closure's i-th upvalue
/// (NO_UPVAL_ADDR if none / already closed). The VM dereferences this.
pub fn getClosureUpvalAddr(obj_idx: u32, i: u16) u32 {
    const c = upvalCell(obj_idx, i);
    if (c == NO_CELL) return NO_UPVAL_ADDR;
    if (cell_closed[c]) return NO_UPVAL_ADDR;
    return cell_addr[c];
}

/// True if a closure's i-th upvalue has been closed (frame returned).
pub fn isClosureUpvalClosed(obj_idx: u32, i: u16) bool {
    const c = upvalCell(obj_idx, i);
    if (c == NO_CELL) return false;
    return cell_closed[c];
}

/// Get the closed (snapshot) value of a closure's i-th upvalue.
pub fn getClosureUpvalClosedVal(obj_idx: u32, i: u16) Value {
    const c = upvalCell(obj_idx, i);
    if (c == NO_CELL) return Value.UNDEFINED;
    return cell_val[c];
}

/// Set the closed value of a closure's i-th upvalue (for set_upval on a
/// closed upvalue) — writes the SHARED cell so all sharers see it.
pub fn setClosureUpvalClosedVal(obj_idx: u32, i: u16, v: Value) void {
    const c = upvalCell(obj_idx, i);
    if (c == NO_CELL) return;
    cell_val[c] = v;
}

/// Capture a closure's i-th upvalue as an already-CLOSED value: allocate a fresh
/// closed cell (transitive capture of an already-closed parent upvalue).
pub fn closeClosureUpval(obj_idx: u32, i: u16, v: Value) void {
    if (obj_idx >= n_objects) return;
    const obj = objects[obj_idx];
    if (i >= obj.n_upvals) return;
    closure_upvals[obj.upval_start + i] = newClosedCell(v);
}

// ── Upvalue closing (driven by the VM on frame return) ──
// The VM closes SHARED CELLS (not per-closure slots) so each captured variable
// is snapshotted exactly once and every sharing closure sees the closed value.
// The VM iterates the COMPACT open-cell list (not all cells) for O(live) cost.
pub fn upvalCellCount() u32 { return n_cells; }
pub fn openCellCount() u32 { return n_open_cells; }
/// Cell index of the k-th open cell (NO_CELL if out of range).
pub fn openCellAt(k: u32) u32 { if (k >= n_open_cells) return NO_CELL; return open_cells[k]; }
/// Live stack address of a cell (NO_UPVAL_ADDR if closed / invalid).
pub fn cellAddr(ci: u32) u32 { if (ci >= n_cells or cell_closed[ci]) return NO_UPVAL_ADDR; return cell_addr[ci]; }
/// Close cell `i` with the given (final) value.
pub fn closeCell(i: u32, v: Value) void {
    if (i >= n_cells) return;
    cell_val[i] = v;
    cell_closed[i] = true;
    cell_addr[i] = NO_UPVAL_ADDR;
}
/// Drop now-closed cells from the compact open list (call after a close pass).
pub fn compactOpenCells() void {
    var w: u32 = 0;
    var r: u32 = 0;
    while (r < n_open_cells) : (r += 1) {
        const ci = open_cells[r];
        if (!cell_closed[ci]) { open_cells[w] = ci; w += 1; }
    }
    n_open_cells = w;
}

/// Bind a closure's i-th upvalue to a SHARED open cell for `addr` (creating the
/// cell if needed). Sibling closures capturing the same variable share it.
pub fn setClosureUpvalAddr(obj_idx: u32, i: u16, addr: u32) void {
    if (obj_idx >= n_objects) return;
    const obj = objects[obj_idx];
    if (i >= obj.n_upvals) return;
    closure_upvals[obj.upval_start + i] = openCellFor(addr);
}

/// Bind a closure's i-th upvalue to share the SAME cell as another closure's
/// j-th upvalue (transitive capture of a still-open parent upvalue). This keeps
/// multi-level captures coherent through the one shared cell.
pub fn shareClosureUpvalCell(dst_obj: u32, dst_i: u16, src_obj: u32, src_i: u16) void {
    if (dst_obj >= n_objects) return;
    const obj = objects[dst_obj];
    if (dst_i >= obj.n_upvals) return;
    closure_upvals[obj.upval_start + dst_i] = upvalCell(src_obj, src_i);
}

// ── Debug accessors: expose a closure's upvalue→cell mapping + cell state ──
pub fn dbgClosureNUpvals(obj_idx: u32) u16 {
    if (obj_idx >= n_objects) return 0;
    return objects[obj_idx].n_upvals;
}
pub fn dbgClosureCellIdx(obj_idx: u32, i: u16) u32 {
    return upvalCell(obj_idx, i);
}
pub fn dbgCellClosed(ci: u32) bool {
    if (ci >= n_cells) return false;
    return cell_closed[ci];
}
pub fn dbgCellAddr(ci: u32) u32 {
    if (ci >= n_cells) return NO_UPVAL_ADDR;
    return cell_addr[ci];
}
pub fn dbgCellVal(ci: u32) Value {
    if (ci >= n_cells) return Value.UNDEFINED;
    return cell_val[ci];
}

/// Create a typed array (Uint8Array, etc.).
pub fn createTypedArray(buffer_id: u32, byte_offset: u32, length: u32, elem_size: u8) u32 {
    if (elem_size != 1 and elem_size != 2 and elem_size != 4) return NULL_OBJ;
    if (buffer_id >= n_objects or objects[buffer_id].obj_type != .array_buffer) return NULL_OBJ;
    const byte_length = @as(u64, length) * elem_size;
    if (byte_offset % elem_size != 0 or @as(u64, byte_offset) + byte_length > objects[buffer_id].byte_length) return NULL_OBJ;
    const idx = allocObject(.typed_array);
    if (idx == NULL_OBJ) return NULL_OBJ;
    objects[idx].buffer_id = buffer_id;
    objects[idx].byte_offset = byte_offset;
    objects[idx].byte_length = @intCast(byte_length);
    objects[idx].elem_size = elem_size;
    objects[idx].array_len = length;
    return idx;
}

/// Create an ArrayBuffer.
pub fn createArrayBuffer(byte_length: u32) u32 {
    const slots_needed: u32 = @intCast((@as(u64, byte_length) + @sizeOf(Value) - 1) / @sizeOf(Value));
    if (slots_needed > MAX_ARRAY_ELEMENTS - n_array_elems) return NULL_OBJ;
    const idx = allocObject(.array_buffer);
    if (idx == NULL_OBJ) return NULL_OBJ;
    // Reserve complete Value slots, and clear bytes even when the pool is reused.
    objects[idx].array_start = n_array_elems;
    objects[idx].byte_length = byte_length;
    n_array_elems += slots_needed;
    if (byte_length > 0) @memset(getBufferBytes(idx), 0);
    return idx;
}

/// Get an object by index.
pub fn getObject(idx: u32) *Object {
    if (idx >= n_objects) return &objects[0]; // safety fallback
    return &objects[idx];
}

pub fn markArguments(obj_idx: u32) void {
    if (obj_idx < n_objects) objects[obj_idx].is_arguments = true;
}

pub fn isArguments(obj_idx: u32) bool {
    return obj_idx < n_objects and objects[obj_idx].is_arguments;
}

fn numericObjectValue(obj_idx: u32) f64 {
    if (obj_idx < n_objects and objects[obj_idx].obj_type == .date) return objects[obj_idx].number_value;
    return @bitCast(@as(u64, 0x7FF8000000000000));
}

pub fn createDate(timestamp_ms: f64, prototype: u32) u32 {
    const idx = allocObject(.date);
    if (idx != NULL_OBJ) {
        objects[idx].number_value = timestamp_ms;
        objects[idx].prototype = prototype;
    }
    return idx;
}

pub fn createNumberWrapper(number: f64) u32 {
    const idx = allocObject(.boxed_number);
    if (idx != NULL_OBJ) { objects[idx].prototype = number_proto; objects[idx].number_value = number; }
    return idx;
}
pub fn createBooleanWrapper(boolean: bool) u32 {
    const idx = allocObject(.boxed_boolean);
    if (idx != NULL_OBJ) { objects[idx].prototype = boolean_proto; objects[idx].array_start = @intFromBool(boolean); }
    return idx;
}
/// String wrappers own immutable UTF-16 character indices in the fixed pool.
pub fn createStringWrapper(string_index: u32) u32 {
    const idx = allocObject(.boxed_string);
    if (idx == NULL_OBJ) return idx;
    objects[idx].prototype = string_proto;
    objects[idx].array_start = string_index;
    const unit_count = values.getStringUnitLength(string_index);
    for (0..unit_count) |i| {
        var buf: [20]u8 = undefined;
        var n = i;
        var start = buf.len;
        while (true) { start -= 1; buf[start] = @intCast('0' + n % 10); n /= 10; if (n == 0) break; }
        const key = values.internString(buf[start..]);
        setProperty(idx, key, Value.string(values.getStringUnit(string_index, i)));
        setWritable(idx, key, false);
        setConfigurable(idx, key, false);
    }
    const length = values.internString("length");
    setProperty(idx, length, Value.number(@floatFromInt(unit_count)));
    setEnumerable(idx, length, false);
    setWritable(idx, length, false);
    setConfigurable(idx, length, false);
    return idx;
}

/// Debug: tag an object as an environment (browser) object for fingerprint
/// probing. See vm.dbg_fp_probe.
pub fn dbgMarkEnvObject(idx: u32) void {
    if (idx >= n_objects) return;
    objects[idx].is_env = true;
}

/// Debug: is this object tagged as an environment object?
pub fn dbgIsEnvObject(idx: u32) bool {
    if (idx >= n_objects) return false;
    return objects[idx].is_env;
}

/// Set a property on an object.
pub var dbg_aR_watch_name: u32 = 0xFFFFFFFF;
pub var dbg_aR_set_count: u32 = 0;
pub var dbg_aR_objs: [16]u32 = [_]u32{0xFFFFFFFF} ** 16;
pub var dbg_aR_tags: [16]u8 = [_]u8{255} ** 16;
pub var dbg_aR_funcs: [16]u16 = [_]u16{0xFFFF} ** 16;
pub fn dbgARFunc(i: usize) u16 { return if (i < 16) dbg_aR_funcs[i] else 0xFFFF; }
pub fn dbgARWatch(name_idx: u32) void { dbg_aR_watch_name = name_idx; dbg_aR_set_count = 0; dbg_track_active = true; }
pub fn dbgARSetCount() u32 { return dbg_aR_set_count; }
pub fn dbgARObj(i: usize) u32 { return if (i < 16) dbg_aR_objs[i] else 0xFFFFFFFF; }
pub fn dbgARTag(i: usize) u8 { return if (i < 16) dbg_aR_tags[i] else 255; }
pub fn setProperty(obj_idx: u32, name_idx: u32, val: Value) void {
    if (obj_idx >= n_objects) return;
    if (name_idx == dbg_aR_watch_name) { if (dbg_aR_set_count < 16) { dbg_aR_objs[dbg_aR_set_count] = obj_idx; dbg_aR_tags[dbg_aR_set_count] = @intFromEnum(val.tag); dbg_aR_funcs[dbg_aR_set_count] = dbg_active_func; } dbg_aR_set_count += 1; }
    const obj = &objects[obj_idx];

    // Update existing property if present (walk the linked list).
    var p: u32 = obj.prop_head;
    while (p != NULL_PROP) {
        if (properties[p].name_idx == name_idx) {
            dbgGuardCheck2(p, obj_idx, name_idx, val, 1);
            if (properties[p].flags.writable) writePropertyValue(&properties[p], val);
            return;
        }
        p = properties[p].next;
    }

    if (!obj.extensible) return;

    // WATCH: capture the FIRST time a "prototype" property is added to a PLAIN
    // object (obj_type .object) — in JS only functions have own "prototype", so
    // this pinpoints the pollution that makes cell.prototype return an object.
    if (dbg_protoset_watch and !dbg_protoset_done and name_idx == dbg_protoset_name and obj.obj_type == .object) {
        dbg_protoset_done = true;
        dbg_protoset_obj = obj_idx;
        dbg_protoset_valtag = @intFromEnum(val.tag);
        dbg_protoset_func = dbg_active_func;
        dbg_protoset_ip = dbg_active_ip;
    }

    // WATCH2: capture EVERY property added to a SPECIFIC target object
    // (dbg_objwatch_target). Records (name, valtag, func, ip) in a ring buffer so
    // we can see exactly who pollutes obj524 with its 12 spurious props.
    if (dbg_objwatch_on and obj_idx == dbg_objwatch_target and dbg_objwatch_n < dbg_objwatch_name.len) {
        const j = dbg_objwatch_n;
        dbg_objwatch_name[j] = name_idx;
        dbg_objwatch_valtag[j] = @intFromEnum(val.tag);
        dbg_objwatch_func[j] = dbg_active_func;
        dbg_objwatch_ip[j] = dbg_active_ip;
        dbg_objwatch_n += 1;
    }
    // GLOBAL: capture the FIRST setProperty writing the number 33040 to ANY
    // object — to find who writes it and whether it aliases obj520's "H" node.
    if (val.tag == .number and val.data.number == 33040.0 and !dbg_v33040_done) {
        dbg_v33040_done = true;
        dbg_v33040_obj = obj_idx;
        dbg_v33040_name = name_idx;
        dbg_v33040_func = dbg_active_func;
        dbg_v33040_ip = dbg_active_ip;
    }
    // TARGETED: record ALL writes to obj520.H (any value tag) in a ring, with
    // value tag + (number value) + func, to see the write sequence. name compared
    // by string to dodge intern-table skew.
    if (dbg_objwatch_on and obj_idx == dbg_objwatch_target) {
        const nm = values.getString(name_idx);
        if (nm.len == 1 and nm[0] == 'H' and dbg_hwrite_n < dbg_hwrite_tag.len) {
            const j = dbg_hwrite_n;
            dbg_hwrite_tag[j] = @intFromEnum(val.tag);
            dbg_hwrite_num[j] = if (val.tag == .number) val.data.number else -987654.0;
            dbg_hwrite_obj[j] = if (val.tag == .object or val.tag == .array or val.tag == .function) val.data.obj_idx else 0xFFFFFFFF;
            dbg_hwrite_func[j] = dbg_active_func;
            dbg_hwrite_n += 1;
        }
    }

    // Prepend a new property node.
    if (n_properties >= MAX_PROPERTIES) { dbg_prop_overflow += 1; return; }
    const idx = n_properties;
    dbgGuardCheck2(idx, obj_idx, name_idx, val, 2);
    properties[idx] = .{ .name_idx = name_idx, .value = val, .next = obj.prop_head };
    n_properties += 1;
    obj.prop_head = idx;
    obj.prop_count += 1;
}
pub var dbg_protoset_watch: bool = false;
pub var dbg_protoset_done: bool = false;
pub var dbg_protoset_name: u32 = 0;
pub var dbg_protoset_obj: u32 = 0xFFFFFFFF;
pub var dbg_protoset_valtag: u8 = 255;
pub var dbg_protoset_func: u16 = 0xFFFF;
pub var dbg_protoset_ip: u32 = 0;
pub var dbg_track_active: bool = false;
pub var dbg_active_func: u16 = 0xFFFF;
pub var dbg_active_ip: u32 = 0;
// Live top-of-stack VM frame func ids (updated each opcode by the VM) so a
// native-triggered corruption can be attributed to the invoking VM function.
pub var dbg_fstack: [6]u16 = [_]u16{0xFFFF} ** 6;
pub var dbg_fstack_n: u8 = 0;
pub fn dbgSetFrameStack(f0: u16, f1: u16, f2: u16, f3: u16, f4: u16, f5: u16, n: u8) void {
    dbg_fstack[0] = f0; dbg_fstack[1] = f1; dbg_fstack[2] = f2; dbg_fstack[3] = f3; dbg_fstack[4] = f4; dbg_fstack[5] = f5; dbg_fstack_n = n;
}
pub var dbg_guard_fstack: [6]u16 = [_]u16{0xFFFF} ** 6;
pub var dbg_guard_fstack_n: u8 = 0;
pub fn dbgGuardFStack(i: usize) u16 { return if (i < 6) dbg_guard_fstack[i] else 0xFFFF; }
pub fn dbgGuardFStackN() u8 { return dbg_guard_fstack_n; }
pub fn dbgProtoSetEnable(name_idx: u32) void { dbg_protoset_watch = true; dbg_protoset_done = false; dbg_protoset_name = name_idx; dbg_track_active = true; }
pub fn dbgProtoSetObj() u32 { return dbg_protoset_obj; }
pub fn dbgProtoSetValTag() u8 { return dbg_protoset_valtag; }
pub fn dbgProtoSetFunc() u16 { return dbg_protoset_func; }
pub fn dbgProtoSetIp() u32 { return dbg_protoset_ip; }
// Targeted per-object property-set watch (records every prop added to one object).
pub var dbg_objwatch_on: bool = false;
pub var dbg_objwatch_target: u32 = 0xFFFFFFFF;
pub var dbg_objwatch_n: usize = 0;
pub var dbg_objwatch_name: [64]u32 = [_]u32{0} ** 64;
pub var dbg_objwatch_valtag: [64]u8 = [_]u8{0} ** 64;
pub var dbg_objwatch_func: [64]u16 = [_]u16{0} ** 64;
pub var dbg_objwatch_ip: [64]u32 = [_]u32{0} ** 64;
pub fn dbgObjWatchEnable(target: u32) void { dbg_objwatch_on = true; dbg_objwatch_target = target; dbg_objwatch_n = 0; dbg_track_active = true; }
pub fn dbgObjWatchN() usize { return dbg_objwatch_n; }
pub fn dbgObjWatchName(i: usize) u32 { return dbg_objwatch_name[i]; }
pub fn dbgObjWatchValTag(i: usize) u8 { return dbg_objwatch_valtag[i]; }
pub fn dbgObjWatchFunc(i: usize) u16 { return dbg_objwatch_func[i]; }
pub fn dbgObjWatchIp(i: usize) u32 { return dbg_objwatch_ip[i]; }
pub var dbg_v33040_done: bool = false;
pub var dbg_v33040_obj: u32 = 0xFFFFFFFF;
pub var dbg_v33040_name: u32 = 0;
pub var dbg_v33040_func: u16 = 0xFFFF;
pub var dbg_v33040_ip: u32 = 0xFFFFFFFF;
pub fn dbgV33040Obj() u32 { return dbg_v33040_obj; }
pub fn dbgV33040Name() u32 { return dbg_v33040_name; }
pub fn dbgV33040Func() u16 { return dbg_v33040_func; }
pub fn dbgV33040Ip() u32 { return dbg_v33040_ip; }
pub var dbg_hwrite_n: usize = 0;
pub var dbg_hwrite_tag: [32]u8 = [_]u8{255} ** 32;
pub var dbg_hwrite_num: [32]f64 = [_]f64{-987654.0} ** 32;
pub var dbg_hwrite_obj: [32]u32 = [_]u32{0xFFFFFFFF} ** 32;
pub var dbg_hwrite_func: [32]u16 = [_]u16{0xFFFF} ** 32;
pub fn dbgHWriteN() usize { return dbg_hwrite_n; }
pub fn dbgHWriteTag(i: usize) u8 { return if (i < 32) dbg_hwrite_tag[i] else 255; }
pub fn dbgHWriteNum(i: usize) f64 { return if (i < 32) dbg_hwrite_num[i] else -987654.0; }
pub fn dbgHWriteObj(i: usize) u32 { return if (i < 32) dbg_hwrite_obj[i] else 0xFFFFFFFF; }
pub fn dbgHWriteFunc(i: usize) u16 { return if (i < 32) dbg_hwrite_func[i] else 0xFFFF; }
pub var dbg_ps_watch: bool = false;
pub var dbg_ps_done: bool = false;
pub var dbg_ps_name: u32 = 0;
pub var dbg_ps_obj: u32 = 0xFFFFFFFF;
pub var dbg_ps_valtag: u8 = 255;
pub var dbg_ps_func: u16 = 0xFFFF;
pub var dbg_ps_ip: u32 = 0;
pub fn dbgPsEnable(name_idx: u32) void { dbg_ps_watch = true; dbg_ps_done = false; dbg_ps_name = name_idx; }
pub fn dbgPsObj() u32 { return dbg_ps_obj; }
pub fn dbgPsValTag() u8 { return dbg_ps_valtag; }
pub fn dbgPsFunc() u16 { return dbg_ps_func; }
pub fn dbgPsIp() u32 { return dbg_ps_ip; }

/// Define an accessor (getter) property: stores the getter function and marks
/// the slot is_getter so the VM invokes it on read (Object.defineProperty with
/// a `get`). BotGuard defines several prototype properties this way.
pub var dbg_setgetter_calls: u32 = 0;
pub var dbg_setgetter_create: u32 = 0;
pub fn setGetterProperty(obj_idx: u32, name_idx: u32, getter: Value) void {
    dbg_setgetter_calls += 1;
    if (name_idx == dbg_resolveset_create_idx) dbg_setgetter_create += 1;
    if (obj_idx >= n_objects) return;
    const obj = &objects[obj_idx];
    var p: u32 = obj.prop_head;
    while (p != NULL_PROP) {
        if (properties[p].name_idx == name_idx) {
            dbgGuardCheck2(p, obj_idx, name_idx, getter, 3);
            properties[p].value = getter;
            properties[p].mapped_cell = NO_CELL;
            properties[p].flags.is_getter = true;
            return;
        }
        p = properties[p].next;
    }
    // WATCH2 (getter path): also record getter-defined props on the target object.
    if (dbg_objwatch_on and obj_idx == dbg_objwatch_target and dbg_objwatch_n < dbg_objwatch_name.len) {
        const j = dbg_objwatch_n;
        dbg_objwatch_name[j] = name_idx;
        dbg_objwatch_valtag[j] = 200; // 200 = getter marker
        dbg_objwatch_func[j] = dbg_active_func;
        dbg_objwatch_ip[j] = dbg_active_ip;
        dbg_objwatch_n += 1;
    }
    if (n_properties >= MAX_PROPERTIES) { dbg_prop_overflow += 1; return; }
    const idx = n_properties;
    dbgGuardCheck2(idx, obj_idx, name_idx, getter, 3);
    properties[idx] = .{ .name_idx = name_idx, .value = getter, .next = obj.prop_head, .flags = .{ .is_getter = true } };
    n_properties += 1;
    obj.prop_head = idx;
    obj.prop_count += 1;
}

/// Accessors retain their independent getter and setter. A function pool index
/// is enough for setters, avoiding a second tagged Value in every property.
pub fn setAccessorProperty(obj_idx: u32, name_idx: u32, getter: Value, setter: Value) void {
    setGetterProperty(obj_idx, name_idx, getter);
    const node = dbgFindPropNode(obj_idx, name_idx);
    if (node == NULL_PROP) return;
    properties[node].setter_fn = if (setter.tag == .function) setter.data.func_idx else NULL_OBJ;
    properties[node].flags.is_setter = setter.tag == .function;
    properties[node].flags.writable = false;
}
/// Object literals define own properties and preserve the other accessor when
/// a getter/setter pair uses the same key. A data definition replaces the pair.
pub fn defineLiteralProperty(obj_idx: u32, name_idx: u32, value: Value, kind: u8) void {
    if (kind == 0) {
        const property = dbgFindPropNode(obj_idx, name_idx);
        if (property != NULL_PROP) { properties[property].flags = .{}; properties[property].setter_fn = NULL_OBJ; }
        setProperty(obj_idx, name_idx, value);
        return;
    }
    var previous: Property = undefined;
    var getter = Value.UNDEFINED;
    var setter = Value.UNDEFINED;
    if (ownPropertyDescriptor(obj_idx, name_idx, &previous) and previous.flags.is_getter) {
        getter = previous.value;
        if (previous.flags.is_setter) setter = Value.function(previous.setter_fn);
    }
    if (kind == 1) getter = value else setter = value;
    setAccessorProperty(obj_idx, name_idx, getter, setter);
    var flags = PropFlags{};
    flags.is_getter = true;
    flags.is_setter = setter.tag == .function;
    flags.writable = false;
    const property = dbgFindPropNode(obj_idx, name_idx);
    if (property != NULL_PROP) properties[property].flags = flags;
}

/// Count how many OWN property nodes an object has with the given name (should
/// be 0 or 1; >1 indicates a duplicate-node corruption).
/// Return the properties-pool INDEX of an object's own property node for the
/// given name, or NULL_PROP if absent.
pub fn dbgFindPropNode(obj_idx: u32, name_idx: u32) u32 {
    if (obj_idx >= n_objects) return NULL_PROP;
    var p: u32 = objects[obj_idx].prop_head;
    while (p != NULL_PROP) {
        if (properties[p].name_idx == name_idx) return p;
        p = properties[p].next;
    }
    return NULL_PROP;
}
// Guard: watch a SPECIFIC property-pool node index; capture the first write
// whose value is NOT an object (the corruption of obj520.H from obj -> 33040).
pub var dbg_guard_node: u32 = 0xFFFFFFFF;
pub var dbg_guard_hit: bool = false;
pub var dbg_guard_valtag: u8 = 255;
pub var dbg_guard_valnum: f64 = -987654.0;
pub var dbg_guard_name: u32 = 0;
pub var dbg_guard_func: u16 = 0xFFFF;
pub var dbg_guard_ip: u32 = 0xFFFFFFFF;
pub var dbg_guard_via: u8 = 0; // 1=setProperty-update 2=setProperty-append 3=setGetter 4=raw
pub fn dbgGuardNodeSet(idx: u32) void { dbg_guard_node = idx; dbg_guard_hit = false; }
pub fn dbgGuardHit() bool { return dbg_guard_hit; }
pub fn dbgGuardValTag() u8 { return dbg_guard_valtag; }
pub fn dbgGuardValNum() f64 { return dbg_guard_valnum; }
pub fn dbgGuardName() u32 { return dbg_guard_name; }
pub fn dbgGuardFunc() u16 { return dbg_guard_func; }
pub fn dbgGuardIp() u32 { return dbg_guard_ip; }
pub fn dbgGuardVia() u8 { return dbg_guard_via; }
/// Find obj's own 1-char-"H" property node index (string-compared to dodge
/// intern skew). Returns NULL_PROP if absent.
pub fn dbgFindPropNodeByChar(obj_idx: u32, ch: u8) u32 {
    if (obj_idx >= n_objects) return NULL_PROP;
    var p: u32 = objects[obj_idx].prop_head;
    while (p != NULL_PROP) {
        const nm = values.getString(properties[p].name_idx);
        if (nm.len == 1 and nm[0] == ch) return p;
        p = properties[p].next;
    }
    return NULL_PROP;
}
pub fn dbgGuardNode() u32 { return dbg_guard_node; }
pub var dbg_guard_objidx: u32 = 0xFFFFFFFF;
pub fn dbgGuardObjIdx() u32 { return dbg_guard_objidx; }
fn dbgGuardCheck2(node: u32, obj_idx: u32, name_idx: u32, val: Value, via: u8) void {
    if (node == dbg_guard_node and dbg_guard_node != 0xFFFFFFFF and !dbg_guard_hit) {
        if (val.tag != .object and val.tag != .function and val.tag != .array) {
            dbg_guard_hit = true;
            dbg_guard_valtag = @intFromEnum(val.tag);
            dbg_guard_valnum = if (val.tag == .number) val.data.number else -987654.0;
            dbg_guard_name = name_idx;
            dbg_guard_objidx = obj_idx;
            dbg_guard_func = dbg_active_func;
            dbg_guard_ip = dbg_active_ip;
            dbg_guard_via = via;
            var gi: usize = 0; while (gi < 6) : (gi += 1) dbg_guard_fstack[gi] = dbg_fstack[gi];
            dbg_guard_fstack_n = dbg_fstack_n;
        }
    }
}

pub fn dbgCountOwnProp(obj_idx: u32, name_idx: u32) u32 {
    if (obj_idx >= n_objects) return 0;
    var n: u32 = 0;
    var p: u32 = objects[obj_idx].prop_head;
    while (p != NULL_PROP) {
        if (properties[p].name_idx == name_idx) n += 1;
        p = properties[p].next;
    }
    return n;
}

/// Get a property from an object (with prototype chain).
pub fn getProperty(obj_idx: u32, name_idx: u32) Value {
    if (obj_idx < n_objects) {
        const obj = objects[obj_idx];
        const name = values.getString(name_idx);
        if (obj.obj_type == .typed_array) {
            if (std.mem.eql(u8, name, "length")) return Value.number(@floatFromInt(obj.array_len));
            if (std.mem.eql(u8, name, "byteOffset")) return Value.number(@floatFromInt(obj.byte_offset));
            if (std.mem.eql(u8, name, "buffer")) return Value.object(obj.buffer_id);
            if (std.mem.eql(u8, name, "BYTES_PER_ELEMENT")) return Value.number(@floatFromInt(obj.elem_size));
        }
        if ((obj.obj_type == .typed_array or obj.obj_type == .array_buffer) and std.mem.eql(u8, name, "byteLength")) return Value.number(@floatFromInt(obj.byte_length));
    }
    var current = obj_idx;
    var depth: u8 = 0;
    while (current != NULL_OBJ and depth < 32) : (depth += 1) {
        if (current >= n_objects) return Value.UNDEFINED;
        var p: u32 = objects[current].prop_head;
        while (p != NULL_PROP) {
            if (properties[p].name_idx == name_idx) return propertyValue(&properties[p]);
            p = properties[p].next;
        }
        if (objects[current].obj_type == .array or objects[current].obj_type == .typed_array) {
            if (arrayIndexName(values.getString(name_idx))) |index| {
                if (hasArrayElement(current, index)) return getArrayElement(current, index);
            }
        }
        current = objects[current].prototype;
    }
    return Value.UNDEFINED;
}

/// Copy an own descriptor, resolving mapped arguments to their current value.
/// Reflecting the property never detaches its parameter alias.
pub fn ownPropertyDescriptor(obj_idx: u32, name_idx: u32, out: *Property) bool {
    if (obj_idx >= n_objects) return false;
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        if (properties[p].name_idx != name_idx) continue;
        out.* = properties[p];
        out.value = propertyValue(&properties[p]);
        return true;
    }
    const obj = &objects[obj_idx];
    if (obj.obj_type == .array) {
        const name = values.getString(name_idx);
        if (name.len == 6 and name[0] == 'l' and name[1] == 'e' and name[2] == 'n' and name[3] == 'g' and name[4] == 't' and name[5] == 'h') {
            out.* = .{ .name_idx = name_idx, .value = Value.number(@floatFromInt(obj.array_len)), .flags = .{ .writable = obj.array_length_writable, .enumerable = false, .configurable = false } };
            return true;
        }
        if (arrayIndexName(name)) |index| {
            if (hasArrayElement(obj_idx, index)) {
                out.* = .{ .name_idx = name_idx, .value = getArrayElement(obj_idx, index) };
                return true;
            }
        }
    }
    return false;
}
/// Apply a validated own descriptor, bypassing assignment's writable check.
/// DefineProperty can replace a configurable readonly property. Assignment
/// cannot. Mapped data properties retain their parameter alias.
pub fn defineOwnProperty(obj_idx: u32, descriptor: Property) bool {
    if (obj_idx >= n_objects) return false;
    const obj = &objects[obj_idx];
    const name = values.getString(descriptor.name_idx);
    if (obj.obj_type == .array and name.len == 6 and name[0] == 'l' and name[1] == 'e' and name[2] == 'n' and name[3] == 'g' and name[4] == 't' and name[5] == 'h') {
        const length: u32 = @intFromFloat(descriptor.value.toNumber());
        arraySetLength(obj_idx, length);
        if (obj.array_len != length) return false;
        obj.array_length_writable = descriptor.flags.writable;
        return true;
    }
    const existing = dbgFindPropNode(obj_idx, descriptor.name_idx);
    if (existing != NULL_PROP) {
        if (descriptor.flags.is_getter) properties[existing].mapped_cell = NO_CELL;
        writePropertyValue(&properties[existing], descriptor.value);
        if (!descriptor.flags.writable) { properties[existing].value = descriptor.value; properties[existing].mapped_cell = NO_CELL; }
        properties[existing].flags = descriptor.flags;
        properties[existing].setter_fn = descriptor.setter_fn;
        return true;
    }
    if ((!obj.extensible and !hasOwnProperty(obj_idx, descriptor.name_idx)) or n_properties == MAX_PROPERTIES) return false;
    if (obj.obj_type == .array) {
        if (arrayIndexName(name)) |index| {
            if (index >= obj.array_len) {
                arraySetLength(obj_idx, index + 1);
                if (obj.array_len <= index) return false;
            }
            deleteArrayElement(obj_idx, index);
        }
    }
    properties[n_properties] = descriptor;
    properties[n_properties].next = obj.prop_head;
    properties[n_properties].mapped_cell = NO_CELL;
    obj.prop_head = n_properties;
    obj.prop_count += 1;
    n_properties += 1;
    return true;
}

/// Look up a property node's is_getter flag (searching the prototype chain).
/// Returns true and sets `out_getter` to the getter function if the property is
/// an accessor; false otherwise.
pub var dbg_getterget_create_found: u32 = 0;
pub var dbg_getterget_create_miss: u32 = 0;
pub fn getPropertyGetter(obj_idx: u32, name_idx: u32, out_getter: *Value) bool {
    var current = obj_idx;
    var depth: u8 = 0;
    while (current != NULL_OBJ and depth < 32) : (depth += 1) {
        if (current >= n_objects) return false;
        var p: u32 = objects[current].prop_head;
        while (p != NULL_PROP) {
            if (properties[p].name_idx == name_idx) {
                if (properties[p].flags.is_getter) { if (name_idx == dbg_resolveset_create_idx) dbg_getterget_create_found += 1; out_getter.* = properties[p].value; return true; }
                if (name_idx == dbg_resolveset_create_idx) dbg_getterget_create_miss += 1;
                return false;
            }
            p = properties[p].next;
        }
        if (objects[current].obj_type == .array or objects[current].obj_type == .typed_array) {
            if (arrayIndexName(values.getString(name_idx))) |index| {
                if (hasArrayElement(current, index)) return false;
            }
        }
        current = objects[current].prototype;
    }
    if (name_idx == dbg_resolveset_create_idx) dbg_getterget_create_miss += 1;
    return false;
}

/// Result of resolving `obj.name = v` against the prototype chain per JS
/// [[Set]] semantics.
pub const SetResolution = enum {
    /// Assign/create an own data property on the receiver (default).
    data,
    /// An accessor with a setter was found; call it (see `out_setter`).
    setter,
    /// An accessor WITHOUT a setter shadows this name — the assignment is a
    /// silent no-op in non-strict mode. BotGuard relies on this: a register
    /// object is `Object.create(protoWithCreateGetter)` then `L.create=fn` must
    /// be ignored so `L.create` keeps running the inherited getter.
    ignore,
};

/// Resolve how `objects[obj_idx].name = v` should behave. Walks the prototype
/// chain: an OWN data property or a missing name yields `.data`; an accessor
/// (own or inherited) yields `.setter` (with the setter) or `.ignore`.
pub var dbg_resolveset_create_idx: u32 = 0xFFFFFFFF; // interned "create"
pub var dbg_resolveset_data: u32 = 0;
pub var dbg_resolveset_ignore: u32 = 0;
pub var dbg_resolveset_setter: u32 = 0;
pub fn resolveSet(obj_idx: u32, name_idx: u32, out_setter: *Value) SetResolution {
    // Own property first: an own data property is written in place; an own
    // accessor uses its setter/ignore.
    if (obj_idx < n_objects) {
        var p: u32 = objects[obj_idx].prop_head;
        while (p != NULL_PROP) {
            if (properties[p].name_idx == name_idx) {
                if (properties[p].flags.is_getter or properties[p].flags.is_setter) {
                    if (properties[p].flags.is_setter) { if (name_idx == dbg_resolveset_create_idx) dbg_resolveset_setter += 1; out_setter.* = Value.function(properties[p].setter_fn); return .setter; }
                    if (name_idx == dbg_resolveset_create_idx) dbg_resolveset_ignore += 1;
                    return .ignore; // getter-only own accessor
                }
                if (name_idx == dbg_resolveset_create_idx) dbg_resolveset_data += 1;
                return .data; // own data property
            }
            p = properties[p].next;
        }
    }
    // Walk the prototype chain for an inherited accessor.
    var current: u32 = if (obj_idx < n_objects) objects[obj_idx].prototype else NULL_OBJ;
    var depth: u8 = 0;
    while (current != NULL_OBJ and depth < 32) : (depth += 1) {
        if (current >= n_objects) break;
        var pp: u32 = objects[current].prop_head;
        while (pp != NULL_PROP) : (pp = properties[pp].next) {
            const p = pp;
            if (properties[p].name_idx == name_idx) {
                if (properties[p].flags.is_setter) { if (name_idx == dbg_resolveset_create_idx) dbg_resolveset_setter += 1; out_setter.* = Value.function(properties[p].setter_fn); return .setter; }
                if (properties[p].flags.is_getter) { if (name_idx == dbg_resolveset_create_idx) dbg_resolveset_ignore += 1; return .ignore; } // inherited getter-only
                if (name_idx == dbg_resolveset_create_idx) dbg_resolveset_data += 1;
                return .data; // inherited data property -> shadow with own data prop
            }
        }
        current = objects[current].prototype;
    }
    return .data;
}

/// Delete an own property (unlink it from the object's property list).
pub fn deleteOwnProperty(obj_idx: u32, name_idx: u32) bool {
    var property: Property = undefined;
    if (ownPropertyDescriptor(obj_idx, name_idx, &property) and !property.flags.configurable) return false;
    deleteProperty(obj_idx, name_idx);
    return true;
}
pub fn deleteProperty(obj_idx: u32, name_idx: u32) void {
    if (obj_idx >= n_objects) return;
    if (objects[obj_idx].obj_type == .array) {
        if (arrayIndexName(values.getString(name_idx))) |index| deleteArrayElement(obj_idx, index);
    }
    const obj = &objects[obj_idx];
    var prev: u32 = NULL_PROP;
    var p: u32 = obj.prop_head;
    while (p != NULL_PROP) {
        if (properties[p].name_idx == name_idx) {
            if (!properties[p].flags.configurable) return;
            properties[p].mapped_cell = NO_CELL;
            if (prev == NULL_PROP) obj.prop_head = properties[p].next
            else properties[prev].next = properties[p].next;
            if (obj.prop_count > 0) obj.prop_count -= 1;
            return;
        }
        prev = p;
        p = properties[p].next;
    }
}

pub fn freezeObject(obj_idx: u32) void {
    if (obj_idx >= n_objects) return;
    objects[obj_idx].extensible = false;
    objects[obj_idx].frozen = true;
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        properties[p].flags.configurable = false;
        if (!properties[p].flags.is_getter and !properties[p].flags.is_setter) properties[p].flags.writable = false;
    }
}

pub fn isFrozen(obj_idx: u32) bool {
    return obj_idx < n_objects and objects[obj_idx].frozen;
}

/// Number of own (non-prototype) properties on an object.
pub fn ownPropCount(obj_idx: u32) u16 {
    if (obj_idx >= n_objects) return 0;
    return objects[obj_idx].prop_count;
}

/// Get the name (string pool index) of the i-th own property. Properties are
pub fn setEnumerable(obj_idx: u32, name_idx: u32, enumerable: bool) void {
    if (obj_idx >= n_objects) return;
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        if (properties[p].name_idx == name_idx) { properties[p].flags.enumerable = enumerable; return; }
    }
}

pub fn setConfigurable(obj_idx: u32, name_idx: u32, configurable: bool) void {
    if (obj_idx >= n_objects) return;
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        if (properties[p].name_idx == name_idx) { properties[p].flags.configurable = configurable; return; }
    }
}

/// Making a mapped index read-only first preserves its current parameter value
/// and then detaches its alias, as required by arguments [[DefineOwnProperty]].
pub fn setWritable(obj_idx: u32, name_idx: u32, writable: bool) void {
    if (obj_idx >= n_objects) return;
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        if (properties[p].name_idx != name_idx) continue;
        if (!writable and properties[p].mapped_cell != NO_CELL) {
            properties[p].value = propertyValue(&properties[p]);
            properties[p].mapped_cell = NO_CELL;
        }
        properties[p].flags.writable = writable;
        return;
    }
}

pub fn isOwnEnumerable(obj_idx: u32, name_idx: u32) bool {
    if (obj_idx >= n_objects) return false;
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        if (properties[p].name_idx == name_idx) return properties[p].flags.enumerable;
    }
    if (objects[obj_idx].obj_type == .array) {
        if (arrayIndexName(values.getString(name_idx))) |index| return hasArrayElement(obj_idx, index);
    }
    return false;
}

/// Canonical array-index string: no leading zeroes and excludes 2^32-1.
pub fn arrayIndexName(name: []const u8) ?u32 {
    if (name.len == 0 or name.len > 10 or (name.len > 1 and name[0] == '0')) return null;
    var index: u64 = 0;
    for (name) |c| {
        if (c < '0' or c > '9') return null;
        index = index * 10 + c - '0';
        if (index >= 4294967295) return null;
    }
    return @intCast(index);
}

fn indexName(index: u32) u32 {
    var buf: [10]u8 = undefined;
    var i = buf.len;
    var n = index;
    while (true) {
        i -= 1; buf[i] = @intCast(n % 10 + '0'); n /= 10;
        if (n == 0) break;
    }
    return values.internString(buf[i..]);
}

fn appendKey(out: []u32, count: *usize, key: u32) void {
    for (out[0..count.*]) |previous| if (previous == key) return;
    if (count.* == out.len) return;
    out[count.*] = key;
    count.* += 1;
}

/// Snapshot own string keys: integer indexes in ascending order, then other
/// names in creation order. The full snapshot includes non-enumerable names
/// so inherited enumeration can suppress shadowed prototype properties.
pub fn enumerateOwnKeys(obj_idx: u32, out: []u32, enumerable_only: bool) usize {
    if (obj_idx >= n_objects) return 0;
    var n: usize = 0;
    if (objects[obj_idx].obj_type == .array) {
        var index: u32 = 0;
        while (index < objects[obj_idx].array_len and n < out.len) : (index += 1) {
            if (hasArrayElement(obj_idx, index)) {
                const key = indexName(index);
                if (!enumerable_only or isOwnEnumerable(obj_idx, key)) appendKey(out, &n, key);
            }
        }
    }
    // Named integer properties share the integer-key prefix (ordinary objects
    // also use this ordering). Insert them into the already sorted prefix.
    var p = objects[obj_idx].prop_head;
    while (p != NULL_PROP) : (p = properties[p].next) {
        const key = properties[p].name_idx;
        const index = arrayIndexName(values.getString(key)) orelse continue;
        if (enumerable_only and !properties[p].flags.enumerable) continue;
        var duplicate = false;
        for (out[0..n]) |previous| if (previous == key) { duplicate = true; break; };
        if (duplicate or n == out.len) continue;
        var at = n;
        while (at > 0 and (arrayIndexName(values.getString(out[at - 1])) orelse 0) > index) : (at -= 1) out[at] = out[at - 1];
        out[at] = key; n += 1;
    }
    if (!enumerable_only) {
        if (objects[obj_idx].obj_type == .array) appendKey(out, &n, values.internString("length"));
        if (objects[obj_idx].obj_type == .function) {
            appendKey(out, &n, values.internString("length"));
            appendKey(out, &n, values.internString("name"));
        }
    }
    var i: usize = ownPropCount(obj_idx);
    while (i > 0) {
        i -= 1;
        const key = ownPropNameAt(obj_idx, @intCast(i));
        if (arrayIndexName(values.getString(key)) != null) continue;
        if (!enumerable_only or isOwnEnumerable(obj_idx, key)) appendKey(out, &n, key);
    }
    return n;
}

/// Snapshot inherited enumerable keys. An own non-enumerable property also
/// shadows a property with the same name on the prototype.
pub fn enumerateKeys(obj_idx: u32, out: []u32) usize {
    var seen: [MAX_ENUM_KEYS]u32 = undefined;
    var own: [MAX_ENUM_KEYS]u32 = undefined;
    var n_seen: usize = 0;
    var n_out: usize = 0;
    var cur = obj_idx;
    var depth: usize = 0;
    while (cur < n_objects and depth < 64) : (depth += 1) {
        const n_own = enumerateOwnKeys(cur, &own, false);
        for (own[0..n_own]) |key| {
            var duplicate = false;
            for (seen[0..n_seen]) |previous| if (previous == key) { duplicate = true; break; };
            if (duplicate) continue;
            if (n_seen == seen.len) return n_out;
            seen[n_seen] = key; n_seen += 1;
            if (isOwnEnumerable(cur, key) and n_out < out.len) { out[n_out] = key; n_out += 1; }
        }
        cur = objects[cur].prototype;
    }
    return n_out;
}

/// Get the name (string pool index) of the i-th own property. Properties are
/// stored newest-first (prepended); we index from the head. Returns 0 if out
/// of range. Order is not spec-exact but stable within a run.
pub fn ownPropNameAt(obj_idx: u32, i: u16) u32 {
    if (obj_idx >= n_objects) return 0;
    var p: u32 = objects[obj_idx].prop_head;
    var k: u16 = 0;
    while (p != NULL_PROP) {
        if (k == i) return properties[p].name_idx;
        k += 1;
        p = properties[p].next;
    }
    return 0;
}

/// Object type of an object index (for iteration: array vs plain object).
pub fn objTypeOf(obj_idx: u32) ObjType {
    if (obj_idx >= n_objects) return .object;
    return objects[obj_idx].obj_type;
}

/// Check if object has own property.
pub fn hasOwnProperty(obj_idx: u32, name_idx: u32) bool {
    if (obj_idx >= n_objects) return false;
    var p: u32 = objects[obj_idx].prop_head;
    while (p != NULL_PROP) {
        if (properties[p].name_idx == name_idx) return true;
        p = properties[p].next;
    }
    if (objects[obj_idx].obj_type == .array) {
        const name = values.getString(name_idx);
        if (name.len == 6 and name[0] == 'l' and name[1] == 'e' and name[2] == 'n' and name[3] == 'g' and name[4] == 't' and name[5] == 'h') return true;
        if (arrayIndexName(name)) |index| return hasArrayElement(obj_idx, index);
    }
    return false;
}

fn elementPresent(abs_index: u32) bool {
    if (abs_index >= n_array_elems) return false;
    return array_present[abs_index / 64] & (@as(u64, 1) << @as(u6, @intCast(abs_index % 64))) != 0;
}

fn setElementPresent(abs_index: u32, present: bool) void {
    if (abs_index >= MAX_ARRAY_ELEMENTS) return;
    const bit = @as(u64, 1) << @as(u6, @intCast(abs_index % 64));
    if (present) array_present[abs_index / 64] |= bit else array_present[abs_index / 64] &= ~bit;
}

pub fn hasArrayElement(obj_idx: u32, index: u32) bool {
    if (obj_idx >= n_objects) return false;
    if (objects[obj_idx].obj_type == .typed_array) return index < objects[obj_idx].array_len;
    if (objects[obj_idx].obj_type != .array) return false;
    const obj = objects[obj_idx];
    return index < obj.array_len and elementPresent(obj.array_start + index);
}

pub fn deleteArrayElement(obj_idx: u32, index: u32) void {
    if (obj_idx >= n_objects or index >= objects[obj_idx].array_len) return;
    const abs_index = objects[obj_idx].array_start + index;
    if (abs_index >= n_array_elems) return;
    array_elements[abs_index] = Value.UNDEFINED;
    setElementPresent(abs_index, false);
}

/// Get array element by index.
pub fn getArrayElement(obj_idx: u32, index: u32) Value {
    if (obj_idx >= n_objects) return Value.UNDEFINED;
    const obj = objects[obj_idx];
    if (obj.obj_type == .typed_array) {
        if (index >= obj.array_len) return Value.UNDEFINED;
        const bytes = getBufferBytes(obj.buffer_id);
        const start = obj.byte_offset + index * obj.elem_size;
        var n: u32 = 0;
        for (0..obj.elem_size) |i| n |= @as(u32, bytes[start + i]) << @as(u5, @intCast(i * 8));
        if (obj.elem_signed) return Value.number(@floatFromInt(@as(i8, @bitCast(@as(u8, @truncate(n))))));
        return Value.number(@floatFromInt(n));
    }
    if (index >= obj.array_len) {
        if (index == dbg_r311_target) { dbg_r311_reads += 1; dbg_r311_last_read_tag = 254; dbg_r311_last_read_obj = obj_idx; recordR311Read(obj_idx); }
        return Value.UNDEFINED;
    }
    const abs_idx = obj.array_start + index;
    if (abs_idx >= n_array_elems) {
        if (index == dbg_r311_target) { dbg_r311_reads += 1; dbg_r311_last_read_tag = 253; dbg_r311_last_read_obj = obj_idx; recordR311Read(obj_idx); }
        return Value.UNDEFINED;
    }
    if (index == dbg_r311_target) { dbg_r311_reads += 1; dbg_r311_last_read_tag = @intFromEnum(array_elements[abs_idx].tag); dbg_r311_last_read_obj = obj_idx; recordR311Read(obj_idx); }
    // Track byte reads of the program (ox) array: index = byte offset = PC>>3.
    // This reveals the actual instruction-fetch PC progression (Node: 0,4,5,6,7...).
    if (obj_idx == dbg_ox_obj and dbg_ox_read_n < dbg_ox_read_seq.len) {
        dbg_ox_read_seq[dbg_ox_read_n] = @intCast(index);
        dbg_ox_read_n += 1;
    }
    return array_elements[abs_idx];
}

fn recordR311Read(obj_idx: u32) void {
    if (dbg_bank_target == 0xFFFF) {
        // First bank to read the faulting register index becomes the watched bank.
        dbg_bank_target = obj_idx;
    }
    var seen = false;
    var ri: usize = 0;
    while (ri < dbg_r311_read_objs_n) : (ri += 1) { if (dbg_r311_read_objs[ri] == obj_idx) seen = true; }
    if (!seen and dbg_r311_read_objs_n < 8) { dbg_r311_read_objs[dbg_r311_read_objs_n] = obj_idx; dbg_r311_read_objs_n += 1; }
}

/// Set array element by index.
pub var dbg_fn_store_count: u32 = 0;
pub var dbg_fn_store_last_arr: u32 = 0xFFFF;
pub var dbg_fn_store_last_idx: u32 = 0;
pub var dbg_fn_store_first_arr: u32 = 0xFFFF;
pub var dbg_fn_store_first_idx: u32 = 0xFFFFFFFF;
// ── Register-bank fault probe (dynamic target index) ──
pub var dbg_r311_target: u32 = 311;
pub var dbg_r311_writes: u32 = 0;
pub var dbg_r311_last_write_tag: u8 = 255;
pub var dbg_r311_last_write_obj: u32 = 0xFFFF;
pub var dbg_r311_reads: u32 = 0;
pub var dbg_r311_last_read_tag: u8 = 255;
pub var dbg_r311_last_read_obj: u32 = 0xFFFF;
pub var dbg_r311_write_objs: [8]u32 = [_]u32{0xFFFFFFFF} ** 8;
pub var dbg_r311_write_objs_n: usize = 0;
pub var dbg_r311_read_objs: [8]u32 = [_]u32{0xFFFFFFFF} ** 8;
pub var dbg_r311_read_objs_n: usize = 0;
// Track the PROGRAM COUNTER register (index 429) values written, to compare
// instruction-stream progression against Node's oracle.
pub var dbg_pc_writes: u32 = 0;
pub var dbg_pos450_n: u32 = 0;
pub var dbg_pos450_seq: [40]u32 = [_]u32{0} ** 40;
pub var dbg_bank_obj: u32 = 0xFFFFFFFF;
pub var dbg_pc_seq: [64]i64 = [_]i64{-1} ** 64;
pub var dbg_pc_seq_n: usize = 0;
pub var dbg_pc_max: i64 = -1;
// Program (ox) byte-read sequence = instruction-fetch byte offsets (PC>>3).
pub var dbg_ox_obj: u32 = 0xFFFF;
pub var dbg_ox_read_seq: [80]i64 = [_]i64{-1} ** 80;
pub var dbg_ox_read_n: usize = 0;
// Reg 176 = decoded-PC stream (write per instruction fetch).
pub var dbg_r176_writes: u32 = 0;
pub var dbg_r176_seq: [80]i64 = [_]i64{-1} ** 80;
pub var dbg_r176_seq_n: usize = 0;
pub var dbg_r176_max: i64 = -1;
// Reads of register index 429 (PC) and 73 (opcode) — the returned VALUE tag,
// to see what the interpreter fetches at each step.

// Watch ALL writes to a specific "bank" object (the faulting register bank):
// track how many distinct register indices get written and the max index.
pub var dbg_bank_target: u32 = 0xFFFF;
pub var dbg_bank_writes: u32 = 0;
pub var dbg_bank_max_idx: i64 = -1;
pub var dbg_bank_target_written: bool = false; // was dbg_r311_target index written on this bank

// ── webPoSignalOutput write watch (minter population) ──
// root.sig sets dbg_webpo_target to the webPoSignalOutput array obj_idx before
// the snapshot; this records every write to it (index + value tag) so we can see
// if/when the VM writes getMinter into webPoSignalOutput[0].
pub var dbg_webpo_target: u32 = 0xFFFFFFFF;
pub var dbg_webpo_writes: u32 = 0;
pub var dbg_webpo_last_idx: u32 = 0xFFFFFFFF;
pub var dbg_webpo_last_tag: u8 = 255;
pub var dbg_webpo_idx0_tag: u8 = 255; // tag of the value written to index 0
pub fn dbgWebpoWrites() u32 { return dbg_webpo_writes; }
pub fn dbgWebpoLastIdx() u32 { return dbg_webpo_last_idx; }
pub fn dbgWebpoLastTag() u8 { return dbg_webpo_last_tag; }
pub fn dbgWebpoIdx0Tag() u8 { return dbg_webpo_idx0_tag; }

pub fn setArrayElement(obj_idx: u32, index: u32, val: Value) void {
    if (obj_idx < n_objects and objects[obj_idx].obj_type == .typed_array) {
        const obj = objects[obj_idx];
        if (index >= obj.array_len) return;
        const numeric = val.toNumber();
        const bits: u64 = @bitCast(numeric);
        const n: u32 = if ((bits & 0x7ff0000000000000) == 0x7ff0000000000000) 0 else @intFromFloat(@mod(@trunc(numeric), 4294967296.0));
        const bytes = getBufferBytes(obj.buffer_id);
        const start = obj.byte_offset + index * obj.elem_size;
        for (0..obj.elem_size) |i| bytes[start + i] = @truncate(n >> @as(u5, @intCast(i * 8)));
        return;
    }
    if (obj_idx == dbg_seed_target and dbg_seed_n < 128) {
        const j = dbg_seed_n;
        dbg_seed_index[j] = index;
        dbg_seed_value[j] = val;
        dbg_seed_func[j] = dbg_active_func;
        dbg_seed_ip[j] = dbg_active_ip;
        dbg_seed_n += 1;
    }
    // ── Minter: catch the write of a STRING to index 3 of a register array
    // (the reg-116 g[3]="d" bug). Record obj/func/ip/str for the first few.
    if (index == 3 and val.tag == .string and dbg_g3w_n < dbg_g3w_obj.len) {
        const j = dbg_g3w_n;
        dbg_g3w_obj[j] = obj_idx;
        dbg_g3w_func[j] = dbg_active_func;
        dbg_g3w_ip[j] = dbg_active_ip;
        const s = values.getString(val.data.str_idx);
        const cn = @min(s.len, 24);
        @memcpy(dbg_g3w_str[j][0..cn], s[0..cn]);
        dbg_g3w_slen[j] = cn;
        dbg_g3w_stridx[j] = val.data.str_idx;
        dbg_g3w_n += 1;
    }
    // ── Minter: trace the ORIGIN of the string "d" (strIdx is run-stable; armed
    // via dbg_dorigin_stridx) — every write of that string to any array slot.
    if (dbg_dorigin_stridx != 0xFFFFFFFF and val.tag == .string and val.data.str_idx == dbg_dorigin_stridx and dbg_dorigin_n < dbg_dorigin_obj.len) {
        const j = dbg_dorigin_n;
        dbg_dorigin_obj[j] = obj_idx;
        dbg_dorigin_index[j] = index;
        dbg_dorigin_func[j] = dbg_active_func;
        dbg_dorigin_ip[j] = dbg_active_ip;
        dbg_dorigin_n += 1;
    }
    if (obj_idx >= n_objects) return;
    // Reg 450 = the interpreter BIT POSITION (advanced by `lo`). Log its first
    // writes to compare the bit-position advance sequence with the reference lo
    // positions (32,40,42,50,52,60,68,...).
    if (index == 450 and val.tag == .number and obj_idx == dbg_bank_obj and dbg_pos450_n < 40) {
        dbg_pos450_seq[dbg_pos450_n] = @intFromFloat(@min(val.data.number, 999999));
        dbg_pos450_n += 1;
    }
    if (index == 429) {
        dbg_bank_obj = obj_idx; // the register bank = the array that receives reg-429 writes
        dbg_pc_writes += 1;
        if (val.tag == .number) {
            const pv: i64 = @intFromFloat(val.data.number);
            if (pv > dbg_pc_max) dbg_pc_max = pv;
            if (dbg_pc_seq_n < dbg_pc_seq.len) { dbg_pc_seq[dbg_pc_seq_n] = pv; dbg_pc_seq_n += 1; }
        }
    }
    // Reg 176 receives the PC at each instruction fetch (`c(176,R,E)`), so its
    // write sequence IS the interpreter's decoded-PC stream. Log it to compare
    // with Node's oracle (E:opcode). This is the ground truth of decode progress.
    if (index == 176 and val.tag == .number) {
        const pv: i64 = @intFromFloat(val.data.number);
        dbg_r176_writes += 1;
        if (pv > dbg_r176_max) dbg_r176_max = pv;
        if (dbg_r176_seq_n < dbg_r176_seq.len) { dbg_r176_seq[dbg_r176_seq_n] = pv; dbg_r176_seq_n += 1; }
    }
    if (obj_idx == dbg_bank_target) {
        dbg_bank_writes += 1;
        if (@as(i64, index) > dbg_bank_max_idx) dbg_bank_max_idx = @intCast(index);
        if (index == dbg_r311_target) dbg_bank_target_written = true;
    }
    if (index == dbg_r311_target) {
        dbg_r311_writes += 1;
        dbg_r311_last_write_tag = @intFromEnum(val.tag);
        dbg_r311_last_write_obj = obj_idx;
        var seen = false;
        var wi: usize = 0;
        while (wi < dbg_r311_write_objs_n) : (wi += 1) { if (dbg_r311_write_objs[wi] == obj_idx) seen = true; }
        if (!seen and dbg_r311_write_objs_n < 8) { dbg_r311_write_objs[dbg_r311_write_objs_n] = obj_idx; dbg_r311_write_objs_n += 1; }
    }
    if (val.tag == .function) {
        dbg_fn_store_count += 1;
        dbg_fn_store_last_arr = obj_idx; dbg_fn_store_last_idx = index;
        if (dbg_fn_store_first_arr == 0xFFFF) { dbg_fn_store_first_arr = obj_idx; dbg_fn_store_first_idx = index; }
    }
    // Track writes to the webPoSignalOutput array (getMinter lands at index 0).
    if (dbg_webpo_target != 0xFFFFFFFF and obj_idx == dbg_webpo_target) {
        dbg_webpo_writes += 1;
        dbg_webpo_last_idx = index;
        dbg_webpo_last_tag = @intFromEnum(val.tag);
        if (index == 0) dbg_webpo_idx0_tag = @intFromEnum(val.tag);
    }
    const obj = &objects[obj_idx];

    // If the write is beyond the reserved capacity, relocate the array to the
    // end of the pool with headroom. WITHOUT this, `array_start + index` could
    // land inside another object's element region (register-bank aliasing) or
    // read uninitialised pool memory — the source of nondeterministic control
    // flow in the interpreted VM (register banks `u.T` grow dynamically).
    if (index >= obj.array_cap) {
        // Grow capacity: at least index+1, with 50% headroom, min 8.
        var new_cap: u32 = index + 1;
        new_cap += new_cap / 2;
        if (new_cap < 8) new_cap = 8;
        if (!relocateArray(obj_idx, new_cap)) {
            // Pool exhausted: best-effort, drop the write rather than corrupt.
            return;
        }
    }

    // Grow logical length, zero-initialising any exposed slots in [old_len,index).
    if (index >= obj.array_len) {
        const start = obj.array_start;
        var k = obj.array_len;
        while (k < index) : (k += 1) {
            array_elements[start + k] = Value.UNDEFINED;
        }
        obj.array_len = index + 1;
    }
    const abs_idx = obj.array_start + index;
    array_elements[abs_idx] = val;
    setElementPresent(abs_idx, true);
}

pub var dbg_seed_target: u32 = 0xFFFFFFFF;
pub var dbg_seed_n: usize = 0;
pub var dbg_seed_index: [128]u32 = undefined;
pub var dbg_seed_value: [128]Value = undefined;
pub var dbg_seed_func: [128]u16 = undefined;
pub var dbg_seed_ip: [128]u32 = undefined;

// Minter: trace origin of a specific interned string across all array writes.
pub var dbg_dorigin_stridx: u32 = 0xFFFFFFFF;
pub var dbg_dorigin_n: usize = 0;
pub var dbg_dorigin_obj: [40]u32 = [_]u32{0} ** 40;
pub var dbg_dorigin_index: [40]u32 = [_]u32{0} ** 40;
pub var dbg_dorigin_func: [40]u16 = [_]u16{0xFFFF} ** 40;
pub var dbg_dorigin_ip: [40]u32 = [_]u32{0} ** 40;
pub fn dbgDoriginN() usize { return dbg_dorigin_n; }
pub fn dbgDoriginObj(i: usize) u32 { return dbg_dorigin_obj[i]; }
pub fn dbgDoriginIndex(i: usize) u32 { return dbg_dorigin_index[i]; }
pub fn dbgDoriginFunc(i: usize) u16 { return dbg_dorigin_func[i]; }
pub fn dbgDoriginIp(i: usize) u32 { return dbg_dorigin_ip[i]; }

// Minter: writes of a STRING to array index 3 (the reg-116 g[3]="d" bug).
pub var dbg_g3w_n: usize = 0;
pub var dbg_g3w_obj: [32]u32 = [_]u32{0} ** 32;
pub var dbg_g3w_func: [32]u16 = [_]u16{0xFFFF} ** 32;
pub var dbg_g3w_ip: [32]u32 = [_]u32{0} ** 32;
pub var dbg_g3w_str: [32][24]u8 = [_][24]u8{[_]u8{0} ** 24} ** 32;
pub var dbg_g3w_slen: [32]usize = [_]usize{0} ** 32;
pub var dbg_g3w_stridx: [32]u32 = [_]u32{0} ** 32;
pub fn dbgG3wN() usize { return dbg_g3w_n; }
pub fn dbgG3wObj(i: usize) u32 { return dbg_g3w_obj[i]; }
pub fn dbgG3wFunc(i: usize) u16 { return dbg_g3w_func[i]; }
pub fn dbgG3wIp(i: usize) u32 { return dbg_g3w_ip[i]; }
pub fn dbgG3wStr(i: usize) []const u8 { return dbg_g3w_str[i][0..dbg_g3w_slen[i]]; }
pub fn dbgG3wStrIdx(i: usize) u32 { return dbg_g3w_stridx[i]; }

/// Move an array's element storage to the end of the pool, reserving `new_cap`
/// slots. Copies existing [0,array_len) elements, zero-inits the remainder.
/// Returns false if the pool cannot fit the new region.
fn relocateArray(obj_idx: u32, new_cap: u32) bool {
    const obj = &objects[obj_idx];
    if (new_cap <= obj.array_cap) return true;
    if (n_array_elems + new_cap > MAX_ARRAY_ELEMENTS) return false;
    const new_start = n_array_elems;
    const old_start = obj.array_start;
    const copy_len = obj.array_len;
    var i: u32 = 0;
    while (i < copy_len) : (i += 1) {
        array_elements[new_start + i] = array_elements[old_start + i];
        setElementPresent(new_start + i, elementPresent(old_start + i));
    }
    while (i < new_cap) : (i += 1) {
        array_elements[new_start + i] = Value.UNDEFINED;
        setElementPresent(new_start + i, false);
    }
    obj.array_start = new_start;
    obj.array_cap = new_cap;
    n_array_elems += new_cap;
    return true;
}

/// Push element to array.
pub fn arrayPush(obj_idx: u32, val: Value) void {
    if (obj_idx >= n_objects) return;
    const obj = &objects[obj_idx];
    setArrayElement(obj_idx, obj.array_len, val);
}

/// Get array length.
pub fn arrayLength(obj_idx: u32) u32 {
    if (obj_idx >= n_objects) return 0;
    return objects[obj_idx].array_len;
}

/// Remove and return the last element (Array.prototype.pop). Shrinks length.
pub fn arrayPop(obj_idx: u32) Value {
    if (obj_idx >= n_objects) return Value.UNDEFINED;
    const obj = &objects[obj_idx];
    if (obj.array_len == 0) return Value.UNDEFINED;
    const v = getArrayElement(obj_idx, obj.array_len - 1);
    deleteArrayElement(obj_idx, obj.array_len - 1);
    obj.array_len -= 1;
    return v;
}

/// Set an array's length (truncate). Used by shift/splice/length-assignment.
pub fn arraySetLength(obj_idx: u32, new_len: u32) void {
    if (obj_idx == 2139 and dbg_resize_n < 32) {
        dbg_resize_rows[dbg_resize_n] = .{ objects[obj_idx].array_len, new_len, dbg_active_func }; dbg_resize_n += 1;
    }
    if (obj_idx >= n_objects) return;
    const obj = &objects[obj_idx];
    if (!obj.array_length_writable and new_len != obj.array_len) return;
    const old_len = obj.array_len;
    if (new_len > obj.array_cap and !relocateArray(obj_idx, new_len)) return;
    // Growing creates holes; it must not expose values left by a previous
    // truncation, shift or splice, or storage belonging to a neighbouring array.
    if (new_len > old_len) {
        for (old_len..new_len) |i| { array_elements[obj.array_start + i] = Value.UNDEFINED; setElementPresent(obj.array_start + @as(u32, @intCast(i)), false); }
    } else {
        for (new_len..old_len) |i| { array_elements[obj.array_start + i] = Value.UNDEFINED; setElementPresent(obj.array_start + @as(u32, @intCast(i)), false); }
    }
    obj.array_len = new_len;
}
pub var dbg_resize_n: usize = 0;
pub var dbg_resize_rows: [32][3]u32 = undefined;

/// Remove and return the first element (Array.prototype.shift). Shifts the rest
/// down by one and decrements length.
pub fn arrayShift(obj_idx: u32) Value {
    if (obj_idx >= n_objects) return Value.UNDEFINED;
    const obj = &objects[obj_idx];
    if (obj.array_len == 0) return Value.UNDEFINED;
    const first = getArrayElement(obj_idx, 0);
    var i: u32 = 1;
    while (i < obj.array_len) : (i += 1) {
        const src = obj.array_start + i;
        const dst = obj.array_start + i - 1;
        if (src < n_array_elems) { array_elements[dst] = array_elements[src]; setElementPresent(dst, elementPresent(src)); }
    }
    deleteArrayElement(obj_idx, obj.array_len - 1);
    obj.array_len -= 1;
    return first;
}

/// Insert a single value at the front (Array.prototype.unshift, single-arg).
/// Shifts existing elements up by one. Returns the new length.
pub fn arrayUnshift(obj_idx: u32, val: Value) u32 {
    if (obj_idx >= n_objects) return 0;
    const obj = &objects[obj_idx];
    // Ensure capacity for one more element (relocate if the region is full),
    // otherwise shifting up would clobber a neighbouring object's storage.
    if (obj.array_len + 1 > obj.array_cap) {
        var new_cap: u32 = obj.array_len + 1;
        new_cap += new_cap / 2;
        if (new_cap < 8) new_cap = 8;
        if (!relocateArray(obj_idx, new_cap)) return obj.array_len;
    }
    // Shift up from the end.
    var i: u32 = obj.array_len;
    while (i > 0) : (i -= 1) {
        const dst = obj.array_start + i;
        const src = obj.array_start + i - 1;
        array_elements[dst] = array_elements[src];
        setElementPresent(dst, elementPresent(src));
    }
    array_elements[obj.array_start] = val;
    setElementPresent(obj.array_start, true);
    obj.array_len += 1;
    return obj.array_len;
}

/// Array.prototype.splice(start, deleteCount) — removes `del` elements starting
/// at `start`, shifting the tail down. Returns the number removed.
pub fn arraySpliceRemove(obj_idx: u32, start_in: u32, del_in: u32) u32 {
    if (obj_idx >= n_objects) return 0;
    const obj = &objects[obj_idx];
    const len = obj.array_len;
    if (start_in >= len) return 0;
    var del = del_in;
    if (start_in + del > len) del = len - start_in;
    if (del == 0) return 0;
    // Shift the tail [start+del .. len) down to [start ..).
    var i: u32 = start_in;
    while (i + del < len) : (i += 1) {
        const src = obj.array_start + i + del;
        const dst = obj.array_start + i;
        if (src < n_array_elems) { array_elements[dst] = array_elements[src]; setElementPresent(dst, elementPresent(src)); }
    }
    var removed_index = len - del;
    while (removed_index < len) : (removed_index += 1) deleteArrayElement(obj_idx, removed_index);
    obj.array_len = len - del;
    return del;
}

/// Make room for `count` elements at `start` (shift tail up), growing length.
/// Used by splice insertion. Elements at [start..start+count) are left for the
/// caller to fill. BotGuard's `H.splice(0,0,x)` inserts an instruction at the
/// FRONT of the interpreter's queue — without this the queue never fills and
/// the interpreter never runs.
pub fn arrayMakeGap(obj_idx: u32, start: u32, count: u32) void {
    if (obj_idx >= n_objects or count == 0) return;
    const obj = &objects[obj_idx];
    const len = obj.array_len;
    if (start > len) return;
    // Ensure capacity for the grown length (relocate if needed), otherwise
    // shifting the tail up would clobber neighbouring object storage.
    if (len + count > obj.array_cap) {
        var new_cap: u32 = len + count;
        new_cap += new_cap / 2;
        if (new_cap < 8) new_cap = 8;
        if (!relocateArray(obj_idx, new_cap)) return;
    }
    // Shift [start..len) up by `count`, from the top down.
    var i: u32 = len;
    while (i > start) : (i -= 1) {
        const src = obj.array_start + i - 1;
        const dst = obj.array_start + i - 1 + count;
        array_elements[dst] = array_elements[src];
        setElementPresent(dst, elementPresent(src));
    }
    // Zero-init the gap so callers that read before filling see undefined.
    var g: u32 = start;
    while (g < start + count) : (g += 1) {
        array_elements[obj.array_start + g] = Value.UNDEFINED;
        setElementPresent(obj.array_start + g, false);
    }
    obj.array_len = len + count;
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
pub fn getBufferBytes(obj_idx: u32) []u8 {
    if (obj_idx >= n_objects) return &[_]u8{};
    const obj = objects[obj_idx];
    if (obj.obj_type != .array_buffer) return &[_]u8{};
    const start = obj.array_start;
    const byte_len = obj.byte_length;
    if (byte_len == 0) return &.{};
    // Reinterpret array_elements storage as bytes
    const ptr: [*]u8 = @ptrCast(&array_elements[start]);
    return ptr[0..byte_len];
}

// ── Internal ──

fn allocObject(obj_type: ObjType) u32 {
    if (n_objects >= MAX_OBJECTS) { dbg_alloc_fail += 1; return NULL_OBJ; }
    const idx = n_objects;
    objects[idx] = .{ .obj_type = obj_type };
    n_objects += 1;
    return idx;
}
pub var dbg_alloc_fail: u32 = 0;
pub fn dbgObjectCount() u32 { return n_objects; }
pub fn dbgObjectMax() u32 { return MAX_OBJECTS; }
