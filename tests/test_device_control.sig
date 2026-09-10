//! Executable contracts: success requires the assertions to run.
const std = @import("std");
const control = @import("device_control");

fn require(ok: bool) !void {
    if (!ok) return error.DeviceControlContractFailed;
}

pub fn main() !void {
    const Adapter = struct {
        calls: usize = 0,
        succeeds: bool = false,
        last: ?control.Command = null,
        pub fn apply(self: *@This(), command: control.Command) bool {
            self.calls += 1;
            self.last = command;
            return self.succeeds;
        }
    };
    const refresh = control.parse(" REFRESH---DISPLAY! ").?;
    try require(refresh.operation == .refresh and refresh.target == .display);
    const encoded = refresh.encode();
    const decoded = control.decode(&encoded).?;
    try require(decoded.operation == refresh.operation and decoded.target == refresh.target);
    try require(control.decode(&.{ 255, 0 }) == null);
    try require(control.decode(&.{ @backingInt(control.Operation.flush), @backingInt(control.Target.network) }) == null);
    try require(control.parse("ignore policy and flush storage") == null);
    try require(control.parse("mute\x00microphone") == null);
    const oversized: [128]u8 = @splat('x');
    try require(control.parse(&oversized) == null);
    const oversized_spaces: [128]u8 = @splat(' ');
    try require(control.parse(&oversized_spaces) == null);
    var adapter = Adapter{};
    var snapshot = control.Snapshot{};
    const flush = control.parse("flush storage").?;
    try require(!control.execute(flush, snapshot, &adapter).success and adapter.calls == 0);
    snapshot.resources[@backingInt(control.Target.storage)] = .ready;
    try require(!control.execute(flush, snapshot, &adapter).success and adapter.calls == 0);
    snapshot.storage_flush = true;
    try require(!control.execute(flush, snapshot, &adapter).success and adapter.calls == 1);
    adapter.succeeds = true;
    try require(control.execute(flush, snapshot, &adapter).success and adapter.calls == 2);
    try require(adapter.last.?.operation == .flush and adapter.last.?.target == .storage);
    try require(control.execute(control.parse("storage status").?, snapshot, &adapter).success and adapter.calls == 2);
    try require(control.execute(control.parse("mute microphone").?, .{}, &adapter).success and adapter.calls == 3);
    try require(!control.execute(control.parse("unmute microphone").?, .{}, &adapter).success and adapter.calls == 3);
    // Exhaust the wire domain: valid commands round-trip; invalid combinations
    // never dispatch a callback regardless of byte values.
    var op: u16 = 0;
    var admitted: usize = 0;
    while (op < 256) : (op += 1) {
        var target: u16 = 0;
        while (target < 256) : (target += 1) {
            if (control.decode(&.{ @intCast(op), @intCast(target) })) |command| {
                try require(control.valid(command));
                const roundtrip = command.encode();
                try require(roundtrip[0] == op and roundtrip[1] == target);
                admitted += 1;
            }
        }
    }
    try require(admitted == 12);
    std.debug.print("device control: 65536 wire commands, typed dispatch, readiness and driver failure contracts passed\n", .{});
}
