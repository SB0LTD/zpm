// Fixed-storage EventTarget listener registry for the embedded browser realm.
// Registration IDs preserve insertion order across removals and nested dispatch.
const values = @import("values.sig");
const objects = @import("objects.sig");
const Value = values.Value;
const std = @import("std");
fn same(a: Value, b: Value) bool { return a.tag == b.tag and a.data.obj_idx == b.data.obj_idx; }
const Listener = struct {
    target: u32 = objects.NULL_OBJ,
    kind: u32 = 0,
    callback: Value = Value.UNDEFINED,
    id: u64 = 0,
    capture: bool = false,
    once: bool = false,
};
const MAX_LISTENERS = 256;
var listeners: [MAX_LISTENERS]Listener = [_]Listener{.{}} ** MAX_LISTENERS;
var next_id: u64 = 1;
const Dispatch = struct { event: u32, immediate: bool = false };
var dispatches: [32]Dispatch = undefined;
var dispatch_depth: usize = 0;
var clicks: [32]u32 = undefined;
var click_depth: usize = 0;
pub fn reset() void { listeners = [_]Listener{.{}} ** MAX_LISTENERS; next_id = 1; dispatch_depth = 0; click_depth = 0; }
pub fn hasCapacity() bool { return dispatch_depth < dispatches.len; }
pub fn isDispatching(event: u32) bool {
    for (dispatches[0..dispatch_depth]) |entry| if (entry.event == event) return true;
    return false;
}
pub fn stopImmediate(event: u32) void {
    for (dispatches[0..dispatch_depth]) |*entry| if (entry.event == event) { entry.immediate = true; return; };
}
pub fn isClicking(target: u32) bool {
    for (clicks[0..click_depth]) |entry| if (entry == target) return true;
    return false;
}
pub fn enterClick(target: u32) bool {
    if (click_depth == clicks.len) return false;
    clicks[click_depth] = target; click_depth += 1; return true;
}
pub fn leaveClick() void { click_depth -= 1; }
fn flag(options: Value, key: []const u8) bool {
    return if (options.tag == .object or options.tag == .array)
        objects.getProperty(options.data.obj_idx, values.internString(key)).isTruthy()
    else if (std.mem.eql(u8, key, "capture")) options.isTruthy() else false;
}
pub fn add(target: u32, kind: u32, callback: Value, options: Value) bool {
    if (callback.tag == .null_val or callback.tag == .undefined) return true;
    const capture = flag(options, "capture");
    for (listeners) |entry| {
        if (entry.target == target and entry.kind == kind and entry.capture == capture and same(entry.callback, callback)) return true;
    }
    for (&listeners) |*entry| {
        if (entry.target != objects.NULL_OBJ) continue;
        entry.* = .{ .target = target, .kind = kind, .callback = callback, .id = next_id, .capture = capture, .once = flag(options, "once") };
        next_id += 1;
        return true;
    }
    return false;
}
pub fn remove(target: u32, kind: u32, callback: Value, options: Value) void {
    const capture = flag(options, "capture");
    for (&listeners) |*entry| {
        if (entry.target == target and entry.kind == kind and entry.capture == capture and same(entry.callback, callback)) { entry.* = .{}; return; }
    }
}
pub const Invoke = *const fn (Value, Value, []const Value) Value;
pub const Aborted = *const fn () bool;
// Dispatch at the target, captures before ordinary listeners. The embedded DOM
// does not yet maintain a tree, so there is no ancestor event path to traverse.
pub fn dispatch(target: u32, event: u32, invoke: Invoke, aborted: Aborted) bool {
    const kind = objects.getProperty(event, values.internString("type"));
    if (kind.tag != .string) return true;
    const cutoff = next_id;
    const depth = dispatch_depth;
    dispatches[depth] = .{ .event = event }; dispatch_depth += 1;
    defer dispatch_depth -= 1;
    objects.setProperty(event, values.internString("target"), Value.object(target));
    objects.setProperty(event, values.internString("currentTarget"), Value.object(target));
    objects.setProperty(event, values.internString("eventPhase"), Value.number(2));
    defer {
        objects.setProperty(event, values.internString("currentTarget"), Value.NULL);
        objects.setProperty(event, values.internString("eventPhase"), Value.number(0));
    }
    for ([_]bool{ true, false }) |capture| {
        var previous: u64 = 0;
        while (!aborted()) {
            if (dispatches[depth].immediate) break;
            var selected: ?usize = null;
            var lowest = cutoff;
            for (listeners, 0..) |entry, i| {
                if (entry.target == target and entry.kind == kind.data.str_idx and entry.capture == capture and entry.id > previous and entry.id < lowest) { selected = i; lowest = entry.id; }
            }
            const i = selected orelse break;
            const entry = listeners[i];
            previous = entry.id;
            if (entry.once) listeners[i] = .{};
            if (entry.callback.tag == .function) {
                _ = invoke(entry.callback, Value.object(target), &.{Value.object(event)});
            } else if (entry.callback.tag == .object or entry.callback.tag == .array) {
                const handler = objects.getProperty(entry.callback.data.obj_idx, values.internString("handleEvent"));
                if (handler.tag == .function) _ = invoke(handler, entry.callback, &.{Value.object(event)});
            }
        }
    }
    if (!aborted() and !dispatches[depth].immediate) {
        const text = values.getString(kind.data.str_idx);
        var key: [256]u8 = undefined;
        if (text.len <= key.len - 2) {
            key[0] = 'o'; key[1] = 'n'; @memcpy(key[2..][0..text.len], text);
            const handler = objects.getProperty(target, values.internString(key[0..text.len+2]));
            if (handler.tag == .function) {
                const result = invoke(handler, Value.object(target), &.{Value.object(event)});
                if (result.tag == .boolean and !result.isTruthy() and objects.getProperty(event, values.internString("cancelable")).isTruthy())
                    objects.setProperty(event, values.internString("defaultPrevented"), Value.TRUE);
            }
        }
    }
    return !objects.getProperty(event, values.internString("defaultPrevented")).isTruthy();
}
