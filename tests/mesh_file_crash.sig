//! Separate process used to die on either side of a real durable replacement.
const std = @import("std");
const history = @import("mesh_history");
const support = @import("mesh_lab_support");
const records = @import("mesh_test_records");
const file = @import("fixed_journal");
const Core = history.Journal(1, 4, 8, records.Counter);
var stage: u64 = 0;
const Observer = struct {
    pub fn beforeReplace() void {
        if (stage == 1) {
            std.debug.print("CRASH before-replace\n", .{});
            support.crash(91);
        }
    }
    pub fn afterReplace() void {
        if (stage == 2) {
            std.debug.print("CRASH after-replace\n", .{});
            support.crash(92);
        }
    }
};
const Backend = struct {
    pub fn load(out: []u8) !?usize {
        return file.load("node-history.bin", out);
    }
    pub fn save(bytes: []const u8) !void {
        return file.saveObserved("node-history.bin", bytes, Observer);
    }
};
var store: Core.Durable(Backend) = undefined;
pub fn main(init: std.process.Init) !void {
    const key = try history.Identity.generateDeterministic(@splat(151));
    const origins = [_]history.Key{key.public_key.toBytes()};
    const create = try support.option(init, "create", 0) != 0;
    try store.init(@splat(72), origins[0], origins, create);
    stage = try support.option(init, "stage", 0);
    if (try support.option(init, "inspect", 0) == 0) try store.append(&key, &records.delta(1));
    const stream = &store.live.streams[0];
    const expected = try support.option(init, "expected", stream.cursor);
    if (stream.cursor != expected or history.get(u64, &stream.state) != expected) return error.WrongRecovery;
    std.debug.print("FILE RECOVERED cursor={d} state={d} generation={d}\n", .{ stream.cursor, history.get(u64, &stream.state), store.live.generation });
}
